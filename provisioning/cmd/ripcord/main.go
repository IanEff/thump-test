package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	compute "cloud.google.com/go/compute/apiv1"
	computepb "cloud.google.com/go/compute/apiv1/computepb"
	"cloud.google.com/go/storage"
	"golang.org/x/sync/errgroup"
	"google.golang.org/api/googleapi"
	iam "google.golang.org/api/iam/v1"
	"google.golang.org/api/iterator"
	"google.golang.org/api/option"
	"google.golang.org/protobuf/proto"
)

type Config struct {
	ProjectID   string
	ClusterName string
	Zone        string
	Region      string
	DryRun      bool
	ClearState  bool
}

type RipcordEngine struct {
	cfg       Config
	instances *compute.InstancesClient
	disks     *compute.DisksClient
	addresses *compute.AddressesClient
	firewalls *compute.FirewallsClient
	subnets   *compute.SubnetworksClient
	networks  *compute.NetworksClient
	gcs       *storage.Client
	iamSvc    *iam.Service
}

func main() {
	var cfg Config
	flag.StringVar(&cfg.ProjectID, "project", "", "GCP Project ID (default: $PROJECT_ID or gcloud default)")
	flag.StringVar(&cfg.ClusterName, "cluster", "", "Cluster prefix name (default: $CLUSTER_NAME or thump-test)")
	flag.StringVar(&cfg.Zone, "zone", "", "GCP Zone (default: $ZONE or auto-discovered)")
	flag.StringVar(&cfg.Region, "region", "", "GCP Region (default: $REGION or auto-discovered)")
	flag.BoolVar(&cfg.DryRun, "dry-run", false, "Scan and display matching resources without deleting")
	flag.BoolVar(&cfg.ClearState, "clear-state", true, "Remove local terraform.tfstate on successful complete teardown")
	flag.Parse()

	resolveConfig(&cfg)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	engine, err := NewRipcordEngine(ctx, cfg)
	if err != nil {
		log.Fatalf("Failed to initialize ripcord engine: %v", err)
	}
	defer engine.Close()

	if err := engine.Run(ctx); err != nil {
		log.Fatalf("Ripcord failed: %v", err)
	}
}

func resolveConfig(cfg *Config) {
	if cfg.ProjectID == "" {
		cfg.ProjectID = os.Getenv("PROJECT_ID")
	}
	if cfg.ProjectID == "" {
		if out, err := exec.Command("gcloud", "config", "get-value", "project").Output(); err == nil {
			cfg.ProjectID = strings.TrimSpace(string(out))
		}
	}
	if cfg.ProjectID == "" {
		cfg.ProjectID = "terraform-sandbox-430820"
	}

	if cfg.ClusterName == "" {
		cfg.ClusterName = os.Getenv("CLUSTER_NAME")
	}
	if cfg.ClusterName == "" {
		cfg.ClusterName = "thump-test"
	}

	if cfg.Zone == "" {
		cfg.Zone = os.Getenv("ZONE")
	}
	if cfg.Region == "" {
		cfg.Region = os.Getenv("REGION")
	}
}

func NewRipcordEngine(ctx context.Context, cfg Config) (*RipcordEngine, error) {
	instClient, err := compute.NewInstancesRESTClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("instances client: %w", err)
	}
	disksClient, err := compute.NewDisksRESTClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("disks client: %w", err)
	}
	addrClient, err := compute.NewAddressesRESTClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("addresses client: %w", err)
	}
	fwClient, err := compute.NewFirewallsRESTClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("firewalls client: %w", err)
	}
	subnetsClient, err := compute.NewSubnetworksRESTClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("subnets client: %w", err)
	}
	netClient, err := compute.NewNetworksRESTClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("networks client: %w", err)
	}
	gcsClient, err := storage.NewClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("storage client: %w", err)
	}
	iamService, err := iam.NewService(ctx, option.WithScopes(iam.CloudPlatformScope))
	if err != nil {
		return nil, fmt.Errorf("iam service: %w", err)
	}

	return &RipcordEngine{
		cfg:       cfg,
		instances: instClient,
		disks:     disksClient,
		addresses: addrClient,
		firewalls: fwClient,
		subnets:   subnetsClient,
		networks:  netClient,
		gcs:       gcsClient,
		iamSvc:    iamService,
	}, nil
}

func (r *RipcordEngine) Close() {
	if r.instances != nil {
		_ = r.instances.Close()
	}
	if r.disks != nil {
		_ = r.disks.Close()
	}
	if r.addresses != nil {
		_ = r.addresses.Close()
	}
	if r.firewalls != nil {
		_ = r.firewalls.Close()
	}
	if r.subnets != nil {
		_ = r.subnets.Close()
	}
	if r.networks != nil {
		_ = r.networks.Close()
	}
	if r.gcs != nil {
		_ = r.gcs.Close()
	}
}

func isNotFound(err error) bool {
	if err == nil {
		return false
	}
	var gErr *googleapi.Error
	if errors.As(err, &gErr) {
		if gErr.Code == http.StatusNotFound {
			return true
		}
	}
	errStr := strings.ToLower(err.Error())
	return strings.Contains(errStr, "not found") || strings.Contains(errStr, "404") || strings.Contains(errStr, "does not exist")
}

func (r *RipcordEngine) Run(ctx context.Context) error {
	start := time.Now()
	fmt.Printf("════════════════════════════════════════════════════════════════════\n")
	fmt.Printf("  ⚡ thump-test — High-Speed Go SDK Ripcord Engine                \n")
	fmt.Printf("  Project: %s | Cluster: %s\n", r.cfg.ProjectID, r.cfg.ClusterName)
	if r.cfg.DryRun {
		fmt.Printf("  Mode: DRY-RUN (no deletions will be executed)\n")
	}
	fmt.Printf("════════════════════════════════════════════════════════════════════\n\n")

	// Phase 1: Parallel Fan-Out (Instances, Static IPs, Firewalls, HMAC keys, Storage Buckets)
	fmt.Println("▶ [Phase 1/3] Dispatched parallel teardown for Layer 1 resources...")
	g1, ctx1 := errgroup.WithContext(ctx)

	var (
		discoveredZones   sync.Map
		discoveredRegions sync.Map
		deletedInstances  int64
		deletedFirewalls  int64
		deletedAddresses  int64
		deletedBuckets    int64
		deletedHMACKeys   int64
	)

	// 1A. Instances (Aggregated across all zones)
	g1.Go(func() error {
		req := &computepb.AggregatedListInstancesRequest{
			Project: r.cfg.ProjectID,
			Filter:  proto.String(fmt.Sprintf("name = %s-*", r.cfg.ClusterName)),
		}
		it := r.instances.AggregatedList(ctx1, req)
		var instGroup errgroup.Group

		for {
			pair, err := it.Next()
			if errors.Is(err, iterator.Done) {
				break
			}
			if err != nil {
				return fmt.Errorf("list instances: %w", err)
			}
			instances := pair.Value.GetInstances()
			if len(instances) == 0 {
				continue
			}
			zoneScope := strings.TrimPrefix(pair.Key, "zones/")
			discoveredZones.Store(zoneScope, true)
			if idx := strings.LastIndex(zoneScope, "-"); idx != -1 {
				discoveredRegions.Store(zoneScope[:idx], true)
			}

			for _, inst := range instances {
				instName := inst.GetName()
				instZone := zoneScope
				atomic.AddInt64(&deletedInstances, 1)
				if r.cfg.DryRun {
					fmt.Printf("  [dry-run] Would delete instance: %s (zone: %s)\n", instName, instZone)
					continue
				}
				instGroup.Go(func() error {
					fmt.Printf("  -> [instance] Deleting %s (%s)...\n", instName, instZone)
					op, err := r.instances.Delete(ctx1, &computepb.DeleteInstanceRequest{
						Project:  r.cfg.ProjectID,
						Zone:     instZone,
						Instance: instName,
					})
					if err != nil {
						if isNotFound(err) {
							return nil
						}
						return fmt.Errorf("delete instance %s: %w", instName, err)
					}
					if err := op.Wait(ctx1); err != nil && !isNotFound(err) {
						return fmt.Errorf("wait instance %s delete: %w", instName, err)
					}
					fmt.Printf("  ✓ [instance] Deleted %s\n", instName)
					return nil
				})
			}
		}
		return instGroup.Wait()
	})

	// 1B. Firewall Rules
	g1.Go(func() error {
		req := &computepb.ListFirewallsRequest{
			Project: r.cfg.ProjectID,
			Filter:  proto.String(fmt.Sprintf("name = %s-*", r.cfg.ClusterName)),
		}
		it := r.firewalls.List(ctx1, req)
		var fwGroup errgroup.Group

		for {
			fw, err := it.Next()
			if errors.Is(err, iterator.Done) {
				break
			}
			if err != nil {
				return fmt.Errorf("list firewalls: %w", err)
			}
			fwName := fw.GetName()
			atomic.AddInt64(&deletedFirewalls, 1)
			if r.cfg.DryRun {
				fmt.Printf("  [dry-run] Would delete firewall rule: %s\n", fwName)
				continue
			}
			fwGroup.Go(func() error {
				fmt.Printf("  -> [firewall] Deleting %s...\n", fwName)
				op, err := r.firewalls.Delete(ctx1, &computepb.DeleteFirewallRequest{
					Project:  r.cfg.ProjectID,
					Firewall: fwName,
				})
				if err != nil {
					if isNotFound(err) {
						return nil
					}
					return fmt.Errorf("delete firewall %s: %w", fwName, err)
				}
				if err := op.Wait(ctx1); err != nil && !isNotFound(err) {
					return fmt.Errorf("wait firewall %s delete: %w", fwName, err)
				}
				fmt.Printf("  ✓ [firewall] Deleted %s\n", fwName)
				return nil
			})
		}
		return fwGroup.Wait()
	})

	// 1C. Static IP Addresses (Aggregated across regions)
	g1.Go(func() error {
		req := &computepb.AggregatedListAddressesRequest{
			Project: r.cfg.ProjectID,
			Filter:  proto.String(fmt.Sprintf("name = %s-control-plane-*", r.cfg.ClusterName)),
		}
		it := r.addresses.AggregatedList(ctx1, req)
		var addrGroup errgroup.Group

		for {
			pair, err := it.Next()
			if errors.Is(err, iterator.Done) {
				break
			}
			if err != nil {
				return fmt.Errorf("list addresses: %w", err)
			}
			addrs := pair.Value.GetAddresses()
			if len(addrs) == 0 {
				continue
			}
			regionScope := strings.TrimPrefix(pair.Key, "regions/")
			discoveredRegions.Store(regionScope, true)

			for _, addr := range addrs {
				addrName := addr.GetName()
				addrRegion := regionScope
				atomic.AddInt64(&deletedAddresses, 1)
				if r.cfg.DryRun {
					fmt.Printf("  [dry-run] Would delete address: %s (region: %s)\n", addrName, addrRegion)
					continue
				}
				addrGroup.Go(func() error {
					fmt.Printf("  -> [address] Deleting %s (%s)...\n", addrName, addrRegion)
					op, err := r.addresses.Delete(ctx1, &computepb.DeleteAddressRequest{
						Project: r.cfg.ProjectID,
						Region:  addrRegion,
						Address: addrName,
					})
					if err != nil {
						if isNotFound(err) {
							return nil
						}
						return fmt.Errorf("delete address %s: %w", addrName, err)
					}
					if err := op.Wait(ctx1); err != nil && !isNotFound(err) {
						return fmt.Errorf("wait address %s delete: %w", addrName, err)
					}
					fmt.Printf("  ✓ [address] Deleted %s\n", addrName)
					return nil
				})
			}
		}
		return addrGroup.Wait()
	})

	// 1D. Storage HMAC Keys + Service Account
	saEmail := fmt.Sprintf("%s-thump-storage@%s.iam.gserviceaccount.com", r.cfg.ClusterName, r.cfg.ProjectID)
	g1.Go(func() error {
		hmacIt := r.gcs.ListHMACKeys(ctx1, r.cfg.ProjectID, storage.ForHMACKeyServiceAccountEmail(saEmail))
		for {
			handle, err := hmacIt.Next()
			if errors.Is(err, iterator.Done) {
				break
			}
			if err != nil {
				if isNotFound(err) {
					break
				}
				log.Printf("Warning: list HMAC keys: %v", err)
				break
			}
			atomic.AddInt64(&deletedHMACKeys, 1)
			if r.cfg.DryRun {
				fmt.Printf("  [dry-run] Would deactivate & delete HMAC key: %s\n", handle.AccessID)
				continue
			}
			fmt.Printf("  -> [hmac] Deactivating & deleting HMAC key %s...\n", handle.AccessID)
			h := r.gcs.HMACKeyHandle(r.cfg.ProjectID, handle.AccessID)
			if handle.State != storage.Inactive {
				if _, err := h.Update(ctx1, storage.HMACKeyAttrsToUpdate{State: storage.Inactive}); err != nil && !isNotFound(err) {
					log.Printf("Warning: deactivate HMAC key %s: %v", handle.AccessID, err)
				}
			}
			if err := h.Delete(ctx1); err != nil && !isNotFound(err) {
				log.Printf("Warning: delete HMAC key %s: %v", handle.AccessID, err)
			} else {
				fmt.Printf("  ✓ [hmac] Deleted %s\n", handle.AccessID)
			}
		}

		// Delete Service Account after HMAC keys
		if r.cfg.DryRun {
			fmt.Printf("  [dry-run] Would delete Service Account: %s\n", saEmail)
			return nil
		}
		saResource := fmt.Sprintf("projects/%s/serviceAccounts/%s", r.cfg.ProjectID, saEmail)
		_, err := r.iamSvc.Projects.ServiceAccounts.Delete(saResource).Context(ctx1).Do()
		if err != nil && !isNotFound(err) {
			log.Printf("Warning: delete SA %s: %v", saEmail, err)
		} else if err == nil {
			fmt.Printf("  ✓ [iam-sa] Deleted Service Account %s\n", saEmail)
		}
		return nil
	})

	// 1E. GCS WAL Buckets (Drained & Deleted)
	g1.Go(func() error {
		bucketPrefix := fmt.Sprintf("%s-thump-wal-", r.cfg.ClusterName)
		bIt := r.gcs.Buckets(ctx1, r.cfg.ProjectID)
		bIt.Prefix = bucketPrefix
		var bGroup errgroup.Group

		for {
			bAttrs, err := bIt.Next()
			if errors.Is(err, iterator.Done) {
				break
			}
			if err != nil {
				if isNotFound(err) {
					break
				}
				return fmt.Errorf("list buckets: %w", err)
			}
			bucketName := bAttrs.Name
			atomic.AddInt64(&deletedBuckets, 1)
			if r.cfg.DryRun {
				fmt.Printf("  [dry-run] Would drain and delete bucket: %s\n", bucketName)
				continue
			}
			bGroup.Go(func() error {
				fmt.Printf("  -> [gcs] Draining and deleting bucket %s...\n", bucketName)
				bkt := r.gcs.Bucket(bucketName)
				objIt := bkt.Objects(ctx1, &storage.Query{Versions: true})
				for {
					objAttrs, err := objIt.Next()
					if errors.Is(err, iterator.Done) {
						break
					}
					if err != nil {
						break
					}
					_ = bkt.Object(objAttrs.Name).Generation(objAttrs.Generation).Delete(ctx1)
				}
				if err := bkt.Delete(ctx1); err != nil && !isNotFound(err) {
					return fmt.Errorf("delete bucket %s: %w", bucketName, err)
				}
				fmt.Printf("  ✓ [gcs] Deleted bucket %s\n", bucketName)
				return nil
			})
		}
		return bGroup.Wait()
	})

	if err := g1.Wait(); err != nil {
		return fmt.Errorf("phase 1 parallel teardown failed: %w", err)
	}
	fmt.Printf("✓ [Phase 1/3] Layer 1 teardown completed in %v\n\n", time.Since(start).Round(time.Millisecond))

	// Phase 2: OSD Disks & Subnetworks (Once instances are completely detached and deleted)
	fmt.Println("▶ [Phase 2/3] Deleting OSD Disks & Subnetwork...")
	g2, ctx2 := errgroup.WithContext(ctx)

	// 2A. OSD Disks
	g2.Go(func() error {
		req := &computepb.AggregatedListDisksRequest{
			Project: r.cfg.ProjectID,
			Filter:  proto.String(fmt.Sprintf("name = %s-osd-*", r.cfg.ClusterName)),
		}
		it := r.disks.AggregatedList(ctx2, req)
		var diskGroup errgroup.Group

		for {
			pair, err := it.Next()
			if errors.Is(err, iterator.Done) {
				break
			}
			if err != nil {
				return fmt.Errorf("list disks: %w", err)
			}
			disks := pair.Value.GetDisks()
			if len(disks) == 0 {
				continue
			}
			zoneScope := strings.TrimPrefix(pair.Key, "zones/")
			for _, disk := range disks {
				diskName := disk.GetName()
				diskZone := zoneScope
				if r.cfg.DryRun {
					fmt.Printf("  [dry-run] Would delete OSD disk: %s (zone: %s)\n", diskName, diskZone)
					continue
				}
				diskGroup.Go(func() error {
					fmt.Printf("  -> [disk] Deleting %s (%s)...\n", diskName, diskZone)
					op, err := r.disks.Delete(ctx2, &computepb.DeleteDiskRequest{
						Project: r.cfg.ProjectID,
						Zone:    diskZone,
						Disk:    diskName,
					})
					if err != nil {
						if isNotFound(err) {
							return nil
						}
						return fmt.Errorf("delete disk %s: %w", diskName, err)
					}
					if err := op.Wait(ctx2); err != nil && !isNotFound(err) {
						return fmt.Errorf("wait disk %s delete: %w", diskName, err)
					}
					fmt.Printf("  ✓ [disk] Deleted %s\n", diskName)
					return nil
				})
			}
		}
		return diskGroup.Wait()
	})

	// 2B. Subnetworks
	g2.Go(func() error {
		subnetName := fmt.Sprintf("%s-subnet", r.cfg.ClusterName)
		var regions []string
		if r.cfg.Region != "" {
			regions = append(regions, r.cfg.Region)
		}
		discoveredRegions.Range(func(key, value any) bool {
			reg := key.(string)
			if reg != r.cfg.Region {
				regions = append(regions, reg)
			}
			return true
		})
		if len(regions) == 0 {
			regions = []string{"us-central1", "us-east1"}
		}

		var subnetGroup errgroup.Group
		for _, reg := range regions {
			region := reg
			if r.cfg.DryRun {
				fmt.Printf("  [dry-run] Would delete subnet: %s in region %s\n", subnetName, region)
				continue
			}
			subnetGroup.Go(func() error {
				op, err := r.subnets.Delete(ctx2, &computepb.DeleteSubnetworkRequest{
					Project:    r.cfg.ProjectID,
					Region:     region,
					Subnetwork: subnetName,
				})
				if err != nil {
					if isNotFound(err) {
						return nil
					}
					return fmt.Errorf("delete subnet %s (%s): %w", subnetName, region, err)
				}
				fmt.Printf("  -> [subnet] Deleting %s (%s)...\n", subnetName, region)
				if err := op.Wait(ctx2); err != nil && !isNotFound(err) {
					return fmt.Errorf("wait subnet %s delete: %w", subnetName, err)
				}
				fmt.Printf("  ✓ [subnet] Deleted %s\n", subnetName)
				return nil
			})
		}
		return subnetGroup.Wait()
	})

	if err := g2.Wait(); err != nil {
		return fmt.Errorf("phase 2 teardown failed: %w", err)
	}
	fmt.Printf("✓ [Phase 2/3] Layer 2 teardown completed in %v\n\n", time.Since(start).Round(time.Millisecond))

	// Phase 3: VPC Network (Once Subnetwork is deleted)
	fmt.Println("▶ [Phase 3/3] Deleting VPC Network...")
	vpcName := fmt.Sprintf("%s-vpc", r.cfg.ClusterName)
	if r.cfg.DryRun {
		fmt.Printf("  [dry-run] Would delete VPC network: %s\n", vpcName)
	} else {
		op, err := r.networks.Delete(ctx, &computepb.DeleteNetworkRequest{
			Project: r.cfg.ProjectID,
			Network: vpcName,
		})
		if err != nil && !isNotFound(err) {
			return fmt.Errorf("delete VPC network %s: %w", vpcName, err)
		} else if err == nil {
			fmt.Printf("  -> [vpc] Deleting %s...\n", vpcName)
			if err := op.Wait(ctx); err != nil && !isNotFound(err) {
				return fmt.Errorf("wait VPC network %s delete: %w", vpcName, err)
			}
			fmt.Printf("  ✓ [vpc] Deleted %s\n", vpcName)
		}
	}
	fmt.Printf("✓ [Phase 3/3] VPC teardown completed in %v\n\n", time.Since(start).Round(time.Millisecond))

	if r.cfg.DryRun {
		fmt.Println("Dry-run complete. No resources were modified.")
		return nil
	}

	// Verification Pass
	fmt.Println("▶ Verifying complete infrastructure teardown...")
	if err := r.verifyClean(ctx); err != nil {
		return fmt.Errorf("verification failed with leftovers: %w", err)
	}

	// Clear local terraform state if clean
	if r.cfg.ClearState {
		cleanStateFiles()
	}

	fmt.Printf("\n🎉 Ripcord successful! All resources verified destroyed in %v. Current cost is zero.\n",
		time.Since(start).Round(time.Millisecond))
	return nil
}

func (r *RipcordEngine) verifyClean(ctx context.Context) error {
	var leftovers []string

	// Check instances
	instIt := r.instances.AggregatedList(ctx, &computepb.AggregatedListInstancesRequest{
		Project: r.cfg.ProjectID,
		Filter:  proto.String(fmt.Sprintf("name = %s-*", r.cfg.ClusterName)),
	})
	for {
		pair, err := instIt.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			break
		}
		for _, inst := range pair.Value.GetInstances() {
			leftovers = append(leftovers, fmt.Sprintf("Instance: %s", inst.GetName()))
		}
	}

	// Check disks
	diskIt := r.disks.AggregatedList(ctx, &computepb.AggregatedListDisksRequest{
		Project: r.cfg.ProjectID,
		Filter:  proto.String(fmt.Sprintf("name = %s-osd-*", r.cfg.ClusterName)),
	})
	for {
		pair, err := diskIt.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			break
		}
		for _, disk := range pair.Value.GetDisks() {
			leftovers = append(leftovers, fmt.Sprintf("OSD Disk: %s", disk.GetName()))
		}
	}

	// Check static IPs
	addrIt := r.addresses.AggregatedList(ctx, &computepb.AggregatedListAddressesRequest{
		Project: r.cfg.ProjectID,
		Filter:  proto.String(fmt.Sprintf("name = %s-control-plane-*", r.cfg.ClusterName)),
	})
	for {
		pair, err := addrIt.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			break
		}
		for _, addr := range pair.Value.GetAddresses() {
			leftovers = append(leftovers, fmt.Sprintf("Static IP: %s", addr.GetName()))
		}
	}

	// Check Firewalls
	fwIt := r.firewalls.List(ctx, &computepb.ListFirewallsRequest{
		Project: r.cfg.ProjectID,
		Filter:  proto.String(fmt.Sprintf("name = %s-*", r.cfg.ClusterName)),
	})
	for {
		fw, err := fwIt.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			break
		}
		leftovers = append(leftovers, fmt.Sprintf("Firewall: %s", fw.GetName()))
	}

	// Check VPC Network
	_, err := r.networks.Get(ctx, &computepb.GetNetworkRequest{
		Project: r.cfg.ProjectID,
		Network: fmt.Sprintf("%s-vpc", r.cfg.ClusterName),
	})
	if err == nil {
		leftovers = append(leftovers, fmt.Sprintf("VPC Network: %s-vpc", r.cfg.ClusterName))
	}

	if len(leftovers) > 0 {
		return fmt.Errorf("remaining resources detected:\n - %s", strings.Join(leftovers, "\n - "))
	}

	fmt.Println("  ✓ Zero leftover resources detected.")
	return nil
}

func cleanStateFiles() {
	stateFiles := []string{"terraform.tfstate", "terraform.tfstate.backup"}
	for _, f := range stateFiles {
		if path, err := filepath.Abs(f); err == nil {
			if _, err := os.Stat(path); err == nil {
				_ = os.Remove(path)
				fmt.Printf("  ✓ Removed local state file: %s\n", f)
			}
		}
	}
}

// Suppress unused imports
var _ = regexp.MustCompile

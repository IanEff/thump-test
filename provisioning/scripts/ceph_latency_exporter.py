import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

class CephLatencyExporter(BaseHTTPRequestHandler):
    def get_metrics(self):
        try:
            # Get list of all OSDs
            osd_list_cmd = ["ceph", "osd", "ls"]
            osds = subprocess.check_output(osd_list_cmd).decode('utf-8').strip().split('\n')
            
            metrics = []
            for osd_id in osds:
                try:
                    # 1. Get Histogram Data
                    perf_hist_cmd = ["ceph", "tell", f"osd.{osd_id}", "perf", "histogram", "dump"]
                    hist_data = json.loads(subprocess.check_output(perf_hist_cmd).decode('utf-8'))
                    osd_hist = hist_data.get("osd", {})
                    
                    # 2. Get Summary Data (for _sum metrics)
                    perf_dump_cmd = ["ceph", "tell", f"osd.{osd_id}", "perf", "dump"]
                    dump_data = json.loads(subprocess.check_output(perf_dump_cmd).decode('utf-8'))
                    osd_summary = dump_data.get("osd", {})

                    for op_type in ["r", "w"]:
                        # Histogram processing
                        key = f"op_{op_type}_latency_out_bytes_histogram" if op_type == "r" else f"op_{op_type}_latency_in_bytes_histogram"
                        hist = osd_hist.get(key)
                        if not hist:
                            continue
                        
                        latency_axis = hist["axes"][0]
                        values_2d = hist["values"]
                        
                        buckets = []
                        cumulative_count = 0
                        
                        for i, range_info in enumerate(latency_axis["ranges"]):
                            bucket_count = sum(values_2d[i])
                            cumulative_count += bucket_count
                            
                            if "max" in range_info and range_info["max"] != -1:
                                le = float(range_info["max"]) / 1_000_000.0
                                buckets.append((le, cumulative_count))
                        
                        buckets.append(("+Inf", cumulative_count))
                        
                        # Labels and metric names
                        labels = f'osd="osd.{osd_id}"'
                        
                        # Native names (for prototype-observability)
                        m_native_bucket = f"ceph_native_osd_op_{op_type}_latency_seconds_bucket"
                        m_native_count = f"ceph_native_osd_op_{op_type}_latency_seconds_count"
                        
                        # Standard names (for elk-slo-dashboard)
                        m_std_bucket = f"ceph_osd_op_{op_type}_latency_bucket"
                        m_std_count = f"ceph_osd_op_{op_type}_latency_count"
                        m_std_sum = f"ceph_osd_op_{op_type}_latency_sum"
                        
                        for le, count in buckets:
                            metrics.append(f'{m_native_bucket}{{{labels},le="{le}"}} {count}')
                            metrics.append(f'{m_std_bucket}{{{labels},le="{le}"}} {count}')
                        
                        metrics.append(f'{m_native_count}{{{labels}}} {cumulative_count}')
                        metrics.append(f'{m_std_count}{{{labels}}} {cumulative_count}')
                        
                        # Get sum from summary data
                        sum_val = osd_summary.get(f"op_{op_type}_latency", {}).get("sum", 0)
                        metrics.append(f'{m_std_sum}{{{labels}}} {sum_val}')

                except Exception as e:
                    print(f"Error scraping OSD {osd_id}: {e}")
            
            return "\n".join(metrics)
        except Exception as e:
            print(f"Global error: {e}")
            return ""

    def do_GET(self):
        if self.path == "/metrics":
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(self.get_metrics().encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8080), CephLatencyExporter)
    print("Ceph Latency Exporter started on port 8080")
    server.serve_forever()

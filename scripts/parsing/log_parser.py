import json
import sys
from statistics import mean, stdev  # For anomaly detection

def load_logs(file_path):
    """Load JSON logs with error handling."""
    logs = []
    try:
        with open(file_path, 'r') as f:
            for line in f:
                log = json.loads(line.strip())
                logs.append(log)
    except FileNotFoundError:
        print("Error: Log file not found.", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON - {e}", file=sys.stderr)
        # Graceful: Skip invalid lines
    return logs

def validate_bid(log):
    """Validate bid data."""
    if 'amount' not in log or log['amount'] <= 0:
        raise ValueError("Invalid bid amount")
    if 'id' not in log:
        raise ValueError("Missing bid ID")
    return True

def detect_anomalies(logs):
    """Simple anomaly detection: Z-score > 2 for bid amounts."""
    amounts = [log['amount'] for log in logs if 'amount' in log]
    if len(amounts) < 2:
        return []
    avg = mean(amounts)
    std = stdev(amounts)
    anomalies = [log for log in logs if 'amount' in log and abs((log['amount'] - avg) / std) > 2]
    return anomalies

def main(log_file):
    logs = load_logs(log_file)
    valid_logs = []
    for log in logs:
        try:
            validate_bid(log)
            valid_logs.append(log)
        except ValueError as e:
            print(f"Validation error: {e}", file=sys.stderr)
    anomalies = detect_anomalies(valid_logs)
    print(f"Processed {len(valid_logs)} valid logs. Anomalies detected: {len(anomalies)}")
    for anomaly in anomalies:
        print(json.dumps(anomaly))

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python log_parser.py <log_file>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
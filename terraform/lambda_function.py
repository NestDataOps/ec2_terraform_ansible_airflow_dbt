import json
import urllib.request
import os
import base64

def lambda_handler(event, context):
    airflow_url = os.environ['AIRFLOW_URL']
    dag_id = os.environ['DAG_ID']
    auth_string = f"{os.environ['AIRFLOW_USER']}:{os.environ['AIRFLOW_PASS']}"
    encoded_auth = base64.b64encode(auth_string.encode('utf-8')).decode('utf-8')
    
    # Extract S3 key from the EventBridge event
    detail = event.get('detail', {})
    key = detail.get('object', {}).get('key')
    
    if not key:
        return {"statusCode": 400, "body": "No key found in event"}

    endpoint = f"{airflow_url}/api/v1/dags/{dag_id}/dagRuns"
    
    # Pass the key to the DAG's params
    payload = json.dumps({"conf": {"s3_key": key}}).encode('utf-8')
    
    req = urllib.request.Request(endpoint, data=payload, method='POST')
    req.add_header('Content-Type', 'application/json')
    req.add_header('Authorization', f'Basic {encoded_auth}')
    
    try:
        with urllib.request.urlopen(req) as response:
            result = response.read().decode('utf-8')
            print(f"Triggered DAG successfully: {result}")
            return {"statusCode": 200, "body": result}
    except Exception as e:
        print(f"Failed to trigger Airflow DAG: {e}")
        raise e

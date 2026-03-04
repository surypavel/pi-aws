import json


def ok(body):
    return {"statusCode": 200, "body": json.dumps(body)}


def err(code, message):
    return {"statusCode": code, "body": json.dumps({"error": message})}

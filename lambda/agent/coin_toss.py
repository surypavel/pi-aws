import random


def handler(event, context):
    result = random.choice(["heads", "tails"])
    return {"result": result}

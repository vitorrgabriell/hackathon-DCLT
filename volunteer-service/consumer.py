import os
import sys
import json
import time
import logging
import boto3
from opentelemetry import trace
from opentelemetry.propagate import extract

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger(__name__)

tracer = trace.get_tracer("volunteer-service.consumer")

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
QUEUE_URL = os.getenv("AWS_SQS_URL")
DYNAMODB_TABLE = os.getenv("AWS_DYNAMODB_TABLE")

if not QUEUE_URL:
    log.critical("Erro: AWS_SQS_URL não definida.")
    sys.exit(1)
if not DYNAMODB_TABLE:
    log.critical("Erro: AWS_DYNAMODB_TABLE não definida.")
    sys.exit(1)

sqs = boto3.client(
    "sqs", region_name=AWS_REGION, endpoint_url=os.getenv("AWS_SQS_ENDPOINT")
)
dynamodb = boto3.resource(
    "dynamodb", region_name=AWS_REGION, endpoint_url=os.getenv("AWS_DYNAMODB_ENDPOINT")
)
table = dynamodb.Table(DYNAMODB_TABLE)


def notify_volunteers(ngo_id):
    response = table.scan(
        FilterExpression=boto3.dynamodb.conditions.Attr("ngo_id").eq(ngo_id)
    )
    volunteers = response.get("Items", [])
    log.info(
        "Notificando %d voluntário(s) da ONG %s sobre nova doação",
        len(volunteers), ngo_id,
    )
    return len(volunteers)


def process_message(message):
    carrier = {
        k: v["StringValue"]
        for k, v in message.get("MessageAttributes", {}).items()
        if "StringValue" in v
    }
    parent_ctx = extract(carrier)

    with tracer.start_as_current_span("process_donation_event", context=parent_ctx) as span:
        try:
            donation = json.loads(message["Body"])
        except (KeyError, json.JSONDecodeError) as e:
            log.error("Evento SQS com corpo inválido: %s", e)
            return

        ngo_id = donation.get("ngo_id")
        span.set_attribute("donation.ngo_id", ngo_id)
        span.set_attribute("donation.id", donation.get("id"))
        notify_volunteers(ngo_id)


def main():
    log.info("volunteer-service consumer iniciado. Fila: %s", QUEUE_URL)
    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
                MessageAttributeNames=["All"],
            )
        except Exception as e:
            log.error("Erro ao consumir SQS: %s", e)
            time.sleep(5)
            continue

        for message in response.get("Messages", []):
            try:
                process_message(message)
            except Exception as e:
                log.error("Erro ao processar mensagem: %s", e)
                continue

            sqs.delete_message(
                QueueUrl=QUEUE_URL, ReceiptHandle=message["ReceiptHandle"]
            )


if __name__ == "__main__":
    main()

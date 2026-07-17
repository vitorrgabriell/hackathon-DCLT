#!/usr/bin/env bash
set -euo pipefail

awslocal dynamodb create-table \
    --table-name SolidaryTechVolunteers \
    --attribute-definitions AttributeName=volunteer_id,AttributeType=S \
    --key-schema AttributeName=volunteer_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST

awslocal sqs create-queue --queue-name solidary-donations

echo "[init-aws] DynamoDB table 'SolidaryTechVolunteers' e fila SQS 'solidary-donations' criadas."

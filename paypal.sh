#!/bin/sh

#  paypal.sh
#  
#
#  Created by Brian A Nooning on 4/18/26.
#  
curl -X POST https://api-m.sandbox.paypal.com/v1/billing/plans \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer A21AAI5WvQ-tTTp7pu_Fimd7psAliCtYXZdj1h2M8DPS1t3osTGkkhck_LZ26j3lOuxbPQlOpJwZBo4--DcjkC16ZBIQ34YrQ" \
  -d '{
    "product_id": "PROD-12W67732BY335572R",
    "name": "EZCompleteUI Monthly Basic",
    "status": "ACTIVE",
    "billing_cycles": [
      {
        "frequency": { "interval_unit": "MONTH", "interval_count": 1 },
        "tenure_type": "REGULAR",
        "sequence": 1,
        "total_cycles": 0,
        "pricing_scheme": {
          "fixed_price": { "value": "9.99", "currency_code": "USD" }
        }
      }
    ],
    "payment_preferences": {
      "auto_bill_outstanding": true,
      "failed_payment_action": "SUSPEND"
    }
  }'

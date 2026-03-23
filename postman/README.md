# API Examples (Postman / cURL)

Use these to hit the PayFlow API after `docker-compose up`. Base URL when running locally: **http://localhost:3000** (API Gateway). Full reference: [../docs/SERVICES.md](../docs/SERVICES.md).

## 1. Register

```bash
curl -X POST http://localhost:3000/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"alice@example.com","password":"securepass123","name":"Alice"}'
```

Response includes `accessToken` and `refreshToken`. Save the `accessToken` for the next steps.

## 2. Log in

```bash
curl -X POST http://localhost:3000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"alice@example.com","password":"securepass123"}'
```

Use the returned `accessToken` in the `Authorization` header below.

## 3. Send money

You need a recipient `userId`. Register a second user (e.g. Bob) and use their `userId` from the register response or from `GET /api/wallets` (admin) or the wallet API.

```bash
export TOKEN="<paste-accessToken-here>"
export TO_USER_ID="<recipient-user-id>"

curl -X POST http://localhost:3000/api/transactions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"toUserId\":\"$TO_USER_ID\",\"amount\":10.50}"
```

Optional: send an **idempotency key** to avoid duplicate charges on retries:

```bash
curl -X POST http://localhost:3000/api/transactions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: unique-key-123" \
  -d "{\"toUserId\":\"$TO_USER_ID\",\"amount\":10.50}"
```

## Postman collection

You can add a `PayFlow.postman_collection.json` in this folder and import it in Postman. The requests above match the same endpoints and bodies.

### Delete a space

```
Example Request
```

```shell
curl "https://api.example.org/v3/spaces/[guid]" \
  -X DELETE \
  -H "Authorization: bearer [token]"
```

```
Example Response
```

```http
HTTP/1.1 202 Accepted
Location: https://api.example.org/v3/jobs/[guid]
```

#### Definition
`DELETE /v3/spaces/:guid`

#### Permitted roles

Role  | Notes
--- | ---
Org manager |
Admin |

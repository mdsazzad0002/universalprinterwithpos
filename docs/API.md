# Universal Print – Integration API

**Version 1.1** · Base URL `http://127.0.0.1:8765`

Universal Print is an Android app that prints directly (no preview) to thermal
printers over Bluetooth or Wi-Fi/LAN. Your software (POS, ERP, web app) sends
JSON; the app turns it into printer commands.

- [How it works](#how-it-works)
- [Quick start](#quick-start-5-minutes)
- [1. Pair once](#1-pair-once)
- [2. Declare your print types (routes)](#2-declare-your-print-types-routes)
- [3. Learn printer sizes](#3-learn-printer-sizes)
- [4. Print](#4-print)
- [Document formats](#document-formats)
- [Job status](#job-status)
- [Sync on startup](#sync-on-startup)
- [Errors](#errors)
- [Endpoint reference](#endpoint-reference)
- [Code examples](#code-examples)

---

## How it works

```
 Your software                        Universal Print app                 Printers
 ─────────────                        ───────────────────                 ────────
 POST /api/print                      route "invoice"  ──▶  Cashier 80mm  🖨
   { route: "kitchen", ... }  ──────▶ route "kitchen"  ──▶  Kitchen 58mm  🖨
                                      route "bar"      ──▶  Bar 58mm      🖨
```

Your software never needs printer addresses. It sends a **route**, which is
the name of a print type such as `invoice`, `kitchen` or `label`. The shop
owner chooses once in the app which printer each route goes to.

| Concept | Who sets it | When |
|---|---|---|
| **Pairing** – your software gets its own token | software asks, user taps *Allow* | once per install |
| **Routes** – the print types your software uses | software declares them | on every startup (sync) |
| **Route → printer** | user in the app (or the software) | once, changeable any time |
| **Paper width** | printer setting, a route override, or per job | any time |

---

## Quick start (5 minutes)

```bash
# 1. Ask to pair (the app shows an "Allow?" dialog with a 6-digit code)
curl -X POST http://127.0.0.1:8765/api/pair \
  -H "Content-Type: application/json" \
  -d '{"client_id":"my-pos","client_name":"My POS – Branch 1"}'
# → {"pairing_id":"8f3c...","code":"482913","status":"pending","expires_in":180}

# 2. Poll until the user taps Allow. The token is returned ONCE, so store it.
curl http://127.0.0.1:8765/api/pair/8f3c...
# → {"status":"approved","token":"a1b2...","printers":[...],"routes":[...]}

# 3. Declare your print types
curl -X PUT http://127.0.0.1:8765/api/routes \
  -H "Authorization: Bearer a1b2..." -H "Content-Type: application/json" \
  -d '{"routes":[{"key":"invoice","name":"Customer invoice"},
                 {"key":"kitchen","name":"Kitchen order"}]}'

# 4. Print
curl -X POST http://127.0.0.1:8765/api/print \
  -H "Authorization: Bearer a1b2..." -H "Content-Type: application/json" \
  -d '{"route":"invoice","reference":"INV-1001",
       "content":{"store_name":"My Shop","invoice_no":"INV-1001",
                  "items":[{"name":"Product A","qty":2,"price":100}],"total":200}}'
```

---

## 1. Pair once

Pairing gives your software its **own token**. The user can see it in the app
and disconnect it, and its routes are kept separate from other software on the
same phone.

### `POST /api/pair` (no auth)

```json
{ "client_id": "my-pos-branch-1", "client_name": "My POS – Branch 1" }
```

| Field | Rule |
|---|---|
| `client_id` | 1–64 chars `A-Z a-z 0-9 _ - .`. Keep it **stable** for the install, because re-pairing with the same id keeps its routes. Cannot be `default`. |
| `client_name` | Shown to the user in the approval dialog. |

Response `202`:

```json
{ "success": true, "pairing_id": "8f3c…", "code": "482913", "status": "pending", "expires_in": 180 }
```

Show the `code` in your software, e.g. *"Confirm code 482913 on the phone"*.
The app shows the same code next to Allow / Reject.

### `GET /api/pair/{pairing_id}` (no auth)

Poll this every 1–2 seconds.

| `status` | Meaning |
|---|---|
| `pending` | Waiting for the user |
| `approved` | Response includes `token` and the full [config](#get-apiconfig). The token is returned **only once**. |
| `rejected` | User tapped Reject |
| `expired` | Not answered within 3 minutes |

After a final status, the pairing is deleted and later calls return `404`.

> **Quick alternative:** for testing or a single in-house app, copy the
> *Master token* from the app's **Connect** tab and skip pairing.

### Using the token

Send it on every other call:

```
Authorization: Bearer <token>
```

You can also send `X-Api-Key: <token>`.

---

## 2. Declare your print types (routes)

### `PUT /api/routes`

Send the full list of print types your software uses. It is safe to call on
every startup.

```json
{
  "routes": [
    { "key": "invoice",  "name": "Customer invoice" },
    { "key": "kitchen",  "name": "Kitchen order", "copies": 1 },
    { "key": "bar",      "name": "Bar order" },
    { "key": "delivery", "name": "Delivery slip", "paper_width_mm": 58 }
  ],
  "prune": false
}
```

| Field | Required | Description |
|---|---|---|
| `key` | ✓ | `a-z 0-9 _ - .`, max 50 chars. This is what you send when printing. |
| `name` | | Label the user sees in the app. Defaults to `key`. |
| `printer_id` | | Assigns the printer from your side. If you leave it out, the user's existing choice is **kept**. |
| `paper_width_mm` | | Lays out this route's jobs for a narrower paper width. |
| `copies` | | Default copies for this route (1–20). |
| `prune` | | `true` removes routes that are not in this list. |

Response:

```json
{
  "success": true,
  "routes": [
    { "key": "invoice", "name": "Customer invoice", "assigned": true,
      "printer_id": "PRN-m9x2k1-a7f3c2", "printer_name": "Cashier", "copies": 1,
      "paper": { "width_mm": 80, "printable_width_mm": 72, "dots_per_line": 576, "chars_per_line": 48, "dpi": 203 } },
    { "key": "kitchen", "name": "Kitchen order", "assigned": false,
      "printer_id": null, "printer_name": null, "copies": 1, "paper": null }
  ],
  "unassigned": ["kitchen"]
}
```

If `unassigned` is not empty, tell the user: *"Open Universal Print → Connect →
My POS and choose a printer for: Kitchen order"*.

> A route that has **no printer yet** prints on the **default printer**, so
> nothing is lost while setup is unfinished. If you print with a `route`
> you never declared, it is created automatically and shows up in the app for
> assignment.

### `GET /api/routes`

Returns the same `routes` array.

---

## 3. Learn printer sizes

Every printer and route reports its exact geometry. Use it to lay out text
yourself, for example padding columns to `chars_per_line`.

### `GET /api/printers`

```json
{
  "success": true,
  "default_printer_id": "PRN-m9x2k1-a7f3c2",
  "printers": [
    {
      "id": "PRN-m9x2k1-a7f3c2",
      "name": "Cashier",
      "connection_type": "bluetooth",
      "protocol": "escpos",
      "is_default": true,
      "auto_cut": true,
      "paper_width": 80,
      "paper": {
        "width_mm": 80,
        "printable_width_mm": 72,
        "dots_per_line": 576,
        "chars_per_line": 48,
        "dpi": 203
      },
      "features": ["text", "bangla", "image", "barcode", "qr", "cut", "cash_drawer", "raw"]
    }
  ]
}
```

| Paper | Printable | Dots/line | Chars/line (Font A) |
|---|---|---|---|
| 58 mm | 48 mm | 384 | 32 |
| 76 mm | 64 mm | 512 | 42 |
| 80 mm | 72 mm | 576 | 48 |
| 112 mm | 104 mm | 832 | 69 |
| other 40–112 mm | ≈ 90 % | width × 7.2 | dots ÷ 12 |

For images, send them at most `dots_per_line` pixels wide. Wider images are
scaled down automatically.

---

## 4. Print

### `POST /api/print`

```json
{
  "route": "kitchen",
  "reference": "ORDER-5521-KOT",
  "copies": 1,
  "paper": { "width_mm": 58 },
  "document_type": "receipt",
  "content": { "...": "..." }
}
```

| Field | Description |
|---|---|
| `route` | Print type key. The app picks the printer. **Recommended.** |
| `printer_id` | Send to this exact printer. Takes priority over `route`. |
| *(neither)* | Default printer. |
| `reference` | Your own unique id (invoice no., order id). A second request with the same `reference` is **not printed again**; you get the first job back with `"duplicate": true`. Use it so retries after a network error are safe. |
| `copies` | 1–20. Default: the route's copies, otherwise 1. |
| `paper.width_mm` | Lays out this job for this paper width (40–112). It must not be wider than the printer's paper. Default: the route's override, otherwise the printer's width. |
| `paper.height_mm` | Reserved for label printers (v2). Thermal receipts use continuous roll, so the length follows the content. |
| `document_type` | `receipt` (default), `elements`, `text`, `raw`. See [Document formats](#document-formats). |

**How the printer and paper width are chosen**

```
printer      =  printer_id  ▸  route's printer  ▸  default printer
paper width  =  paper.width_mm  ▸  route's paper_width_mm  ▸  printer's paper width
copies       =  copies  ▸  route's copies  ▸  1
```

Response `202 Accepted` (`200` when it is a duplicate):

```json
{
  "success": true,
  "duplicate": false,
  "job_id": "JOB-m9x5aa-0f12e4",
  "status": "pending",
  "printer_id": "PRN-m9x2k1-b81d07",
  "printer_name": "Kitchen",
  "route": "kitchen",
  "paper_width_mm": 58,
  "document_type": "receipt",
  "copies": 1,
  "reference": "ORDER-5521-KOT",
  "error": null,
  "attempts": 0,
  "created_at": "2026-11-03T15:40:12.120",
  "updated_at": "2026-11-03T15:40:12.120"
}
```

### `POST /api/print/batch`

Sends one order to several printers in one call, for example an invoice plus
the kitchen and bar tickets. Up to 20 jobs.

```json
{
  "jobs": [
    { "route": "invoice", "reference": "ORD-77-INV", "content": { "...": "..." } },
    { "route": "kitchen", "reference": "ORD-77-KOT", "document_type": "text", "content": "Table 4\n2x Biriyani" },
    { "route": "bar",     "reference": "ORD-77-BAR", "document_type": "text", "content": "Table 4\n2x Lemonade" }
  ]
}
```

Response `207` returns one result per job, in the same order. A failed job
does not stop the others.

```json
{ "success": false, "results": [ { "success": true, "job_id": "…" }, { "success": true, "job_id": "…" }, { "success": false, "error": "…" } ] }
```

---

## Document formats

Bangla and any other Unicode text print correctly on every printer. The app
draws them as images, so the printer does not need a Bangla font.

### `receipt`: ready-made invoice layout

```json
{
  "document_type": "receipt",
  "content": {
    "store_name": "আমার দোকান",
    "header": ["Mirpur 10, Dhaka", "01700-000000"],
    "title": "INVOICE",
    "invoice_no": "INV-1001",
    "date": "2026-11-03 15:40",
    "customer": "Rahim",
    "info": [{ "label": "Table", "value": "4" }, { "label": "Waiter", "value": "Karim" }],
    "items": [
      { "name": "চাল (মিনিকেট)", "qty": 2, "price": 70 },
      { "name": "Product B", "qty": 1, "price": 250, "total": 240 }
    ],
    "subtotal": 380, "discount": 10, "vat": 0, "service_charge": 0,
    "total": 370, "paid": 500, "change": 130,
    "footer": ["Thank you!", "ধন্যবাদ"],
    "barcode": "INV-1001",
    "qr": "https://myshop.com/i/INV-1001"
  }
}
```

All fields are optional, but you must send `items` or `total`. For an item,
`total` defaults to `qty × price`.

### `elements`: full control of the layout

```json
{
  "document_type": "elements",
  "elements": [
    { "type": "image", "base64": "iVBORw0KGgo…", "width": 300 },
    { "type": "text", "value": "KITCHEN ORDER", "align": "center", "bold": true, "size": 2 },
    { "type": "line" },
    { "type": "row", "left": "Table", "right": "4" },
    { "type": "row", "left": "2x Chicken Biriyani", "right": "Spicy", "bold": true },
    { "type": "feed", "lines": 2 },
    { "type": "qr", "value": "ORD-77", "size": 6 },
    { "type": "cut" }
  ]
}
```

| `type` | Fields |
|---|---|
| `text` | `value`, `align` (`left` \| `center` \| `right`), `bold`, `size` (1–4) |
| `row` | `left`, `right`, `bold`. Left and right are aligned to the paper width. |
| `line` | `char` (default `-`) |
| `feed` | `lines` |
| `barcode` | `value` (CODE128), `height` (dots, default 80) |
| `qr` | `value`, `size` (1–16, default 6) |
| `image` | `base64` (PNG/JPEG, `data:` prefix allowed), `width` (dots), `align` (default `center`) |
| `cut` | `full` (default partial cut) |
| `cash_drawer` | Opens the drawer connected to the printer |
| `raw` | `base64` printer bytes inserted as-is |

If the printer's *Auto cut* setting is on and your document has no `cut`, a
cut is added at the end.

### `text`: plain text

```json
{ "document_type": "text", "content": "Line 1\nLine 2" }
```

### `raw`: your own printer bytes

```json
{ "document_type": "raw", "data": "G0AbYQFIZWxsbwoKCh1WQgA=" }
```

The bytes are sent unchanged, with no auto cut. Use this if you already
generate ESC/POS yourself.

---

## Job status

### `GET /api/jobs/{job_id}`

```
pending ──▶ processing ──▶ printing ──▶ completed
   │                          │
   └──▶ cancelled             └──▶ failed   (error says why)
```

| Status | Meaning |
|---|---|
| `pending` | In the queue |
| `processing` | Building printer data |
| `printing` | Sending to the printer (retried once on connection errors) |
| `completed` | All data reached the printer. Most printers cannot confirm that paper actually came out. |
| `failed` | `error` gives the reason, e.g. `Cannot reach 192.168.1.50:9100`. The user can tap *Print again* in the app. |
| `cancelled` | Cancelled by the user before printing |

Jobs for the same printer always print in the order they were sent.

---

## Sync on startup

### `GET /api/config`

Everything in one call: who you are, all printers with their sizes, and your
routes.

```json
{
  "success": true,
  "client": { "client_id": "my-pos-branch-1", "client_name": "My POS – Branch 1", "paired_at": "…" },
  "default_printer_id": "PRN-…",
  "printers": [ /* same as GET /api/printers */ ],
  "routes":   [ /* same as GET /api/routes */ ]
}
```

**Recommended startup flow**

```
start
  │
  ├─ token saved? ── no ──▶ POST /api/pair ▶ show code ▶ poll ▶ save token
  │
  ├─ PUT /api/routes      (declare your print types)
  │
  ├─ GET /api/config      (cache printers + routes; show "not assigned" warnings)
  │
  └─ ready → POST /api/print with { route, reference }
        │
        └─ 401 → token was revoked in the app → pair again
```

Re-sync whenever your print types change, or when the user opens your
printer settings page. Changes made in the app, such as a new printer for a
route, apply to the next print immediately. Your software does not need to
know about them.

---

## Errors

```json
{ "success": false, "error": "Route \"kitchen\" has no printer assigned and there is no default printer", "code": "invalid_request" }
```

| HTTP | When | What to do |
|---|---|---|
| `401` | Missing, invalid or revoked token | Pair again |
| `404` | Unknown job, pairing or path | |
| `413` | Body larger than 10 MB | Send smaller images |
| `422` | Invalid payload, unknown printer, paper wider than the printer | Fix the request; `error` says what is wrong |
| `429` | Too many pairing requests waiting | Wait for the user to answer |
| `500` | Unexpected app error | Report it |

A job that was accepted (`202`) but fails at the printer does **not** return
an HTTP error. Check `GET /api/jobs/{id}`.

---

## Endpoint reference

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/ping` | – | App is running? Returns `version` |
| POST | `/api/pair` | – | Ask to pair |
| GET | `/api/pair/{pairing_id}` | – | Pairing status (and token once approved) |
| GET | `/api/config` | ✓ | Client, printers, routes in one call |
| GET | `/api/printers` | ✓ | Printers with paper geometry |
| GET | `/api/routes` | ✓ | Your routes and their printers |
| PUT | `/api/routes` | ✓ | Declare / sync routes |
| POST | `/api/print` | ✓ | Print one document |
| POST | `/api/print/batch` | ✓ | Print up to 20 documents |
| GET | `/api/jobs/{job_id}` | ✓ | Job status |

### Network access

| Your software runs on | URL |
|---|---|
| The same Android phone (app or browser) | `http://127.0.0.1:8765` |
| Another device on the same Wi-Fi | Turn on **Connect → Allow other devices on Wi-Fi**, then use `http://<phone-ip>:8765` |

CORS is open, so browser `fetch()` works, including from HTTPS pages in
Chrome. The port can be changed in the app.

---

## Code examples

### JavaScript (web POS)

```js
const BASE = 'http://127.0.0.1:8765';
const CLIENT = { client_id: 'my-web-pos', client_name: 'My Web POS' };

async function ensurePaired(showCode) {
  let token = localStorage.getItem('up_token');
  if (token) return token;
  const start = await (await fetch(`${BASE}/api/pair`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(CLIENT),
  })).json();
  showCode(start.code);                                   // "Confirm 482913 on the phone"
  for (;;) {
    await new Promise(r => setTimeout(r, 1500));
    const s = await (await fetch(`${BASE}/api/pair/${start.pairing_id}`)).json();
    if (s.status === 'approved') { localStorage.setItem('up_token', s.token); return s.token; }
    if (s.status !== 'pending') throw new Error('Pairing ' + s.status);
  }
}

async function api(token, method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body && JSON.stringify(body),
  });
  if (res.status === 401) { localStorage.removeItem('up_token'); throw new Error('Re-pair needed'); }
  return res.json();
}

// startup
const token = await ensurePaired(code => alert(`Confirm code ${code} on the phone`));
await api(token, 'PUT', '/api/routes', { routes: [
  { key: 'invoice', name: 'Customer invoice' },
  { key: 'kitchen', name: 'Kitchen order' },
]});

// print
await api(token, 'POST', '/api/print', {
  route: 'invoice', reference: 'INV-1001',
  content: { store_name: 'আমার দোকান', items: [{ name: 'চাল', qty: 2, price: 70 }], total: 140 },
});
```

### PHP / Laravel (server on the same Wi-Fi)

```php
use Illuminate\Support\Facades\Http;

$up = Http::baseUrl('http://192.168.1.20:8765')   // phone IP, "Allow other devices" ON
    ->withToken(config('services.universal_print.token'))
    ->acceptJson();

$up->put('/api/routes', ['routes' => [
    ['key' => 'invoice', 'name' => 'Customer invoice'],
    ['key' => 'kitchen', 'name' => 'Kitchen order'],
]])->throw();

$res = $up->post('/api/print', [
    'route'     => 'invoice',
    'reference' => $invoice->number,
    'content'   => [
        'store_name' => 'My Shop',
        'invoice_no' => $invoice->number,
        'items'      => $invoice->items->map(fn ($i) => [
            'name' => $i->name, 'qty' => $i->qty, 'price' => $i->price,
        ])->all(),
        'total'      => $invoice->total,
    ],
])->throw()->json();

// $res['job_id'], $res['status']
```

### Android (Kotlin, same phone)

```kotlin
val body = """{"route":"invoice","reference":"INV-1001","document_type":"text","content":"Hello"}"""
val conn = URL("http://127.0.0.1:8765/api/print").openConnection() as HttpURLConnection
conn.requestMethod = "POST"
conn.setRequestProperty("Authorization", "Bearer $token")
conn.setRequestProperty("Content-Type", "application/json")
conn.doOutput = true
conn.outputStream.use { it.write(body.toByteArray()) }
val json = conn.inputStream.bufferedReader().readText()
```

On Android 9 and newer, allow cleartext traffic to `127.0.0.1` in your app's
network security config.

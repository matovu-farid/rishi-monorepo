# App Store Connect — Rishi Reader & Voice subscriptions

Fill-in reference for the **Rishi Reader & Voice** group (`rishi-reader-voice-group`).

**App:** Rishi Reader (`org.fidexa.rishi`)  
**Localization:** English (U.S.)  
**ASC Description limit:** **must be less than 45 characters** (Apple’s validation)

---

## Copy-paste NOW (ASC modal only)

Paste **only** these two lines into **Add App Store Localization**.  
Do **not** paste anything from “Plan details” below.

### Rishi Voice Monthly (`org.fidexa.rishi.voice.monthly`)

```
Rishi Voice Monthly
```

```
12h AI narration + 180m Voice Chat/mo.
```

(Display Name = 19 chars · Description = 38 chars)

### Rishi Voice Annual (`org.fidexa.rishi.voice.annual`)

```
Rishi Voice Annual
```

```
12h AI narration + 180m Voice Chat/yr.
```

(Display Name = 18 chars · Description = 38 chars)

### Rishi Reader Monthly (`org.fidexa.rishi.reader.monthly`)

```
Rishi Reader Monthly
```

```
6h AI narration + 90m Voice Chat/mo.
```

(Display Name = 20 chars · Description = 36 chars)

### Rishi Reader Annual (`org.fidexa.rishi.reader.annual`)

```
Rishi Reader Annual
```

```
6h AI narration + 90m Voice Chat/yr.
```

(Display Name = 19 chars · Description = 36 chars)

---

## Other ASC fields (not the localization modal)

| Product ID | Reference Name | Duration | Level | US price | Family Sharing |
| --- | --- | --- | --- | --- | --- |
| `org.fidexa.rishi.voice.monthly` | Rishi Voice Monthly | 1 month | **1** | $14.99 | Off |
| `org.fidexa.rishi.voice.annual` | Rishi Voice Annual | 1 year | **1** | $143.99 | Off |
| `org.fidexa.rishi.reader.monthly` | Rishi Reader Monthly | 1 month | **2** | $7.99 | Off |
| `org.fidexa.rishi.reader.annual` | Rishi Reader Annual | 1 year | **2** | $76.99 | Off |

### Group

| Field | Value |
| --- | --- |
| Reference Name | `rishi-reader-voice-group` |
| Display Name | Rishi Reader & Voice |
| Description | Rishi Reader and Rishi Voice subscriptions |

Level **1** = Voice (higher). Level **2** = Reader (lower).

---

## Plan details (NOT for ASC Description field)

Internal / review context only. Apple will reject these if pasted into Description.

**Voice (monthly or annual billing)**  
- 12 hours AI narration per month  
- 180 minutes Voice Chat per month  
- Books remain fully readable without using allowance  

**Reader (monthly or annual billing)**  
- 6 hours AI narration per month  
- 90 minutes Voice Chat per month  
- Books remain fully readable without using allowance  

Annual products: same monthly allowances; billed yearly.

### Optional App Review notes

- Voice Monthly: `Auto-renewable. 12h AI narration + 180m Voice Chat/mo. ID org.fidexa.rishi.voice.monthly.`  
- Voice Annual: `Annual billing; same monthly Voice allowances. ID org.fidexa.rishi.voice.annual.`  
- Reader Monthly: `Auto-renewable. 6h AI narration + 90m Voice Chat/mo. ID org.fidexa.rishi.reader.monthly.`  
- Reader Annual: `Annual billing; same monthly Reader allowances. ID org.fidexa.rishi.reader.annual.`

---

## Legacy Pro

Do not use for new setup: `org.fidexa.rishi.pro.monthly`, `org.fidexa.rishi.pro.annual`. Keep only for grandfathered subscribers. Do not put Reader/Voice SKUs in the old Rishi Pro group.

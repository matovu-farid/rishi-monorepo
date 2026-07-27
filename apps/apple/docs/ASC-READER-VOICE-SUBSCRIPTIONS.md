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

### Rishi Reader Monthly (`rishi.reader.monthly`)

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
| `rishi.reader.monthly` | Rishi Reader Monthly | 1 month | **2** | $7.99 | Off |
| `org.fidexa.rishi.reader.annual` | Rishi Reader Annual | 1 year | **2** | $76.99 | Off |
| `org.fidexa.rishi.voice.monthly.macos` | Rishi Voice Monthly macOS | 1 month | **1** | $14.99 | Off |
| `org.fidexa.rishi.voice.annual.macos` | Rishi Voice Annual macOS | 1 year | **1** | $99.99 | Off |
| `org.fidexa.rishi.reader.monthly.macos` | Rishi Reader Monthly macOS | 1 month | **2** | $7.99 | Off |
| `org.fidexa.rishi.reader.annual.macos` | Rishi Reader Annual macOS | 1 year | **2** | $79.99 | Off |

### Group

### macOS localization values used for the new records

| Product ID | Display Name | Description |
| --- | --- | --- |
| `org.fidexa.rishi.voice.monthly.macos` | Rishi Voice Monthly | 12h AI narration, 540 min Voice Chat monthly. |
| `org.fidexa.rishi.voice.annual.macos` | Rishi Voice Annual | 12h AI narration, 540 min Voice Chat. Billed yearly. |
| `org.fidexa.rishi.reader.monthly.macos` | Rishi Reader Monthly | 6h AI narration, 270 min Voice Chat monthly. |
| `org.fidexa.rishi.reader.annual.macos` | Rishi Reader Annual | 6h AI narration, 270 min Voice Chat. Billed yearly. |

The macOS records use all-country availability. Family Sharing, introductory/promotional offers, and review screenshots/notes remain separate ASC fields and must be verified independently per product.

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
- 540 minutes Voice Chat per month  
- Books remain fully readable without using allowance  

**Reader (monthly or annual billing)**  
- 6 hours AI narration per month  
- 270 minutes Voice Chat per month  
- Books remain fully readable without using allowance  

Annual products: same monthly allowances; billed yearly.

### Optional App Review notes

- Voice Monthly: `Auto-renewable. 12h AI narration + 540m Voice Chat/mo. ID org.fidexa.rishi.voice.monthly.`  
- Voice Annual: `Annual billing; same monthly Voice allowances. ID org.fidexa.rishi.voice.annual.`  
- Reader Monthly: `Auto-renewable. 6h AI narration + 270m Voice Chat/mo. ID rishi.reader.monthly.`
- Reader Annual: `Annual billing; same monthly Reader allowances. ID org.fidexa.rishi.reader.annual.`

### Mac Catalyst review notes — reaching and subscribing to plans

1. Launch Rishi Reader on macOS using the Mac Catalyst build and sign in with the review account.
2. Open the **Account** menu in the macOS menu bar.
3. For an account without an active subscription, choose **Subscribe…**. The app opens the native StoreKit subscription sheet. If the account already has an active plan, the menu item is **Manage Subscription…** instead.
4. Select the desired plan card, confirm the selected radio/check control, and press **Subscribe** at the bottom of the sheet.
5. Complete the App Store sandbox purchase confirmation when prompted. After returning to the app, the entitlement refresh updates the account to the selected plan.

The four Mac Catalyst plans are:

| Plan shown in the sheet | Billing | Price | Product ID | How to subscribe |
|---|---:|---:|---|---|
| Rishi Reader Monthly | Monthly | $7.99/month | `org.fidexa.rishi.reader.monthly.macos` | Choose **Rishi Reader Monthly**, then press **Subscribe**. |
| Rishi Voice Monthly | Monthly | $14.99/month | `org.fidexa.rishi.voice.monthly.macos` | Choose **Rishi Voice Monthly**, then press **Subscribe**. |
| Rishi Reader Annual | Annual | $79.99/year | `org.fidexa.rishi.reader.annual.macos` | Scroll to **Rishi Reader Annual**, choose it, then press **Subscribe**. |
| Rishi Voice Annual | Annual | $99.99/year | `org.fidexa.rishi.voice.annual.macos` | Scroll to **Rishi Voice Annual**, choose it, then press **Subscribe**. |

The sheet may require scrolling on smaller Catalyst windows. The purchase button is fixed at the bottom of the StoreKit sheet; the selected plan’s price and renewal terms appear in that button area before confirmation.

For a clean review run, use a sandbox account with no existing Rishi subscription. Existing subscribers should test **Manage Subscription…** separately and should not be asked to purchase the same active plan again.

---

## Legacy Pro

Do not use for new setup: `org.fidexa.rishi.pro.monthly`, `org.fidexa.rishi.pro.annual`. Keep only for grandfathered subscribers. Do not put Reader/Voice SKUs in the old Rishi Pro group.

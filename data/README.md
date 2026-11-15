# Data

| File | Content |
|---|---|
| `Orders.csv` | 51,290 order lines × 24 columns (Row ID, Order ID, dates, ship mode, customer, segment, geography, market, product, category, sales, quantity, discount, profit, shipping cost, order priority) |
| `Returns.csv` | 1,079 returned orders (`Returned`, `Order ID`, `Region`) |

**Source**: the files look like the public *Global Superstore* sales dataset. Add the exact link you downloaded them from here, and check its licence; remove the files from the repository if redistribution is not allowed.

Facts checked on the files: `Order ID` is unique in `Returns.csv` (the join adds no rows); `Postal Code` is 80.5% missing (column dropped); 2,600 lines have a shipping delay of 0 days.

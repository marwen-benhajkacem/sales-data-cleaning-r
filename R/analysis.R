# ==========================================================================
# Sales data cleaning, feature engineering and analysis (Orders + Returns)
# Run from the project root:  Rscript R/analysis.R
# Requires data/Orders.csv and data/Returns.csv (see data/README.md)
# ==========================================================================
# install.packages(c("dplyr", "tidyr", "data.table", "ggplot2", "scales"))   # once
suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(data.table); library(ggplot2); library(scales)
})
dir.create("results/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("results/tables",  recursive = TRUE, showWarnings = FALSE)
save_plot <- function(p, name, w = 8, h = 5) ggsave(file.path("results/figures", name), p, width = w, height = h, dpi = 150)

# ---- 1. Import -----------------------------------------------------------
orders  <- read.csv("data/Orders.csv")
returns <- read.csv("data/Returns.csv")
cat("Orders:", dim(orders), "| Returns:", dim(returns), "\n")
str(orders); str(returns)

# ---- 2. Missing values ----------------------------------------------------
na_pct <- orders %>% summarise(across(everything(), ~ mean(is.na(.)) * 100))
print(round(t(na_pct), 2))
orders$Postal.Code <- NULL            # mostly missing / not needed
cat("NA left in orders:", sum(is.na(orders)), "\n")

# ---- 3. Sort, drop id -----------------------------------------------------
orders <- orders %>% arrange(Row.ID)
orders$Row.ID <- NULL

# ---- 4. Dates: year, month, shipping delay -------------------------------
orders$Order.Date <- as.Date(orders$Order.Date, format = "%Y-%m-%d")
orders$Ship.Date  <- as.Date(orders$Ship.Date,  format = "%Y-%m-%d")
stopifnot(!anyNA(orders$Order.Date), !anyNA(orders$Ship.Date))   # fail early if the date format differs
orders <- orders %>% mutate(
  order_year      = format(Order.Date, "%Y"),
  order_month_num = as.integer(format(Order.Date, "%m")),
  order_month     = month.name[order_month_num],
  ShipDays        = as.numeric(Ship.Date - Order.Date)
)
orders$Ship.Date <- NULL; orders$Order.Date <- NULL

# ---- 5. Market -> one-hot columns ----------------------------------------
orders <- orders %>%
  mutate(Market_flag = 1) %>%
  pivot_wider(names_from = Market, values_from = Market_flag, values_fill = 0, names_glue = "{Market}_market")

# ---- 6. Join with Returns -------------------------------------------------
orders <- left_join(orders, returns, by = "Order.ID")
orders <- orders %>% select(-any_of(c("Region.x", "Region.y", "Customer.ID")))
orders <- orders %>% mutate(Returned = ifelse(is.na(Returned), "No", Returned))

# ---- 7. Derived variables -------------------------------------------------
orders <- orders %>%
  mutate(across(c(Profit, Sales, Shipping.Cost, Discount), ~ round(., 2))) %>%
  rename(Sales_with_discount = Sales) %>%
  mutate(
    Profit.Net    = Profit - Shipping.Cost,
    Margin_Profit = round(Profit.Net / Sales_with_discount * 100, 2),
    profit_flag   = if_else(Profit.Net >= 0, "Profit", "Loss"),
    # OrderScore = 0.5*margin% + 20/ShipDays - 30 if returned (ShipDays floored at 1 to avoid division by zero)
    OrderScore    = Margin_Profit * 0.5 + (1 / pmax(ShipDays, 1)) * 20 + ifelse(Returned == "Yes", -30, 0),
    Margin_Category = case_when(
      Margin_Profit >= 30 ~ "High Margin",
      Margin_Profit >= 15 ~ "Medium Margin",
      Margin_Profit >= 0  ~ "Low Margin",
      TRUE                ~ "Negative Margin")
  ) %>%
  unite("Exact_location", City, State, sep = "_")
str(orders)

# ---- 8. KPIs ---------------------------------------------------------------
Discounted_Orders_Ratio <- mean(orders$Discount > 0)
Avg_ShipDays_High <- orders %>% filter(Order.Priority == "High") %>% summarise(avg = mean(ShipDays)) %>% pull(avg)
kpi_table <- data.frame(
  Total_Sales      = sum(orders$Sales_with_discount, na.rm = TRUE),
  Total_Units_Sold = sum(orders$Quantity, na.rm = TRUE),
  Total_Orders     = nrow(orders),
  Total_Customers  = n_distinct(orders$Customer.Name),
  Avg_Ship_Cost    = mean(orders$Shipping.Cost, na.rm = TRUE),
  Total_Profit_Net = sum(orders$Profit.Net, na.rm = TRUE),
  Discounted_Orders_Ratio = Discounted_Orders_Ratio,
  Avg_ShipDays_High_Priority = Avg_ShipDays_High
)
print(t(kpi_table)); write.csv(kpi_table, "results/tables/kpi_table.csv", row.names = FALSE)

# ---- 9. Aggregations --------------------------------------------------------
stats_cat <- orders %>% group_by(Category) %>%
  summarise(total_sales = sum(Sales_with_discount), avg_sales = mean(Sales_with_discount), n_orders = n())
stats_seg <- orders %>% group_by(Segment) %>% summarise(avg_profit = mean(Profit.Net), n_orders = n())
return_seg <- orders %>% group_by(Segment) %>% summarise(return_rate = mean(Returned == "Yes") * 100)
orders_cat <- stats_cat %>% select(Category, n_orders)      # (was used but never defined in the first version)

# Top 10 products: dplyr version and data.table version (must give the same result)
top_products <- orders %>% group_by(Product.Name) %>% summarise(total_sales = sum(Sales_with_discount)) %>%
  arrange(desc(total_sales)) %>% slice(1:10)
dt <- as.data.table(orders)
top_dt <- dt[, .(total_sales = sum(Sales_with_discount)), by = Product.Name][order(-total_sales)][1:10]
stopifnot(isTRUE(all.equal(top_products$total_sales, top_dt$total_sales)))

monthly <- orders %>% group_by(order_year, order_month_num, order_month) %>%
  summarise(total_sales = sum(Sales_with_discount), n_orders = n(), .groups = "drop") %>%
  arrange(order_year, order_month_num)

for (nm in c("stats_cat", "stats_seg", "return_seg", "top_products", "monthly"))
  write.csv(get(nm), file.path("results/tables", paste0(nm, ".csv")), row.names = FALSE)

# ---- 10. Charts ---------------------------------------------------------------
red <- "#A93226"
p1 <- ggplot(orders, aes(ShipDays)) + geom_histogram(bins = 40, fill = "#D35400", color = "black") +
  labs(title = "Shipping delay distribution", x = "Days", y = "Count") + theme_minimal()
p2 <- ggplot(return_seg, aes(Segment, return_rate, fill = Segment)) + geom_col() +
  labs(title = "Return rate (%) by segment", x = "Segment", y = "Return rate (%)") + theme_minimal()
p3 <- ggplot(orders, aes(Ship.Mode, ShipDays, fill = Ship.Mode)) + geom_boxplot() +
  labs(title = "Shipping delay by ship mode", x = "Ship mode", y = "Days") + theme_minimal()
units_year <- orders %>% group_by(order_year) %>% summarise(total_units = sum(Quantity)) %>% mutate(order_year = as.numeric(order_year))
p4 <- ggplot(units_year, aes(order_year, total_units)) + geom_line(color = red, linewidth = 1.4) +
  labs(title = "Total units sold by year", x = "Year", y = "Units") + theme_minimal(base_size = 14)
sales_year <- orders %>% group_by(order_year) %>% summarise(total_sales = sum(Sales_with_discount))
p5 <- ggplot(sales_year, aes(order_year, total_sales, group = 1)) + geom_line(color = red, linewidth = 1.3) +
  labs(title = "Total sales by year", x = "Year", y = "Sales") + theme_minimal(base_size = 14)
returns_by_shipmode <- orders %>% filter(Returned == "Yes") %>% group_by(Ship.Mode) %>% summarise(total_returns = n())
p6 <- ggplot(returns_by_shipmode, aes(Ship.Mode, total_returns)) + geom_col(fill = red, width = 0.7) +
  labs(title = "Returns by ship mode", x = "Ship mode", y = "Number of returns") + theme_minimal(base_size = 14)
p7 <- ggplot(orders, aes(OrderScore)) + geom_histogram(fill = red, color = "white", bins = 30) +
  labs(title = "OrderScore distribution", x = "OrderScore", y = "Frequency") + theme_minimal()
p8 <- ggplot(orders, aes(Margin_Category, fill = Margin_Category)) + geom_bar() + scale_fill_brewer(palette = "Reds") +
  labs(title = "Margin categories", x = "Margin category", y = "Count") + theme_minimal()
p9 <- ggplot(orders_cat, aes("", n_orders, fill = Category)) + geom_col(width = 1) + coord_polar("y") +
  geom_text(aes(label = paste0(round(n_orders / sum(n_orders) * 100, 1), "%")),
            position = position_stack(vjust = 0.5), color = "white", size = 5) +
  scale_fill_brewer(palette = "Reds") + labs(title = "Orders by category", fill = "Category") + theme_void()
bubble_data <- orders %>% group_by(Category) %>%
  summarise(total_sales = sum(Sales_with_discount), total_profit = sum(Profit.Net), total_shipping = sum(Shipping.Cost))
p10 <- ggplot(bubble_data, aes(total_shipping, total_profit, size = total_sales, color = Category)) +
  geom_point(alpha = 0.8) + scale_size(range = c(10, 30), guide = "none") +
  scale_color_manual(values = c("Furniture" = "#F1948A", "Office Supplies" = "#E74C3C", "Technology" = "#CB4335")) +
  scale_x_continuous(labels = label_number(scale = 1e-3, suffix = "k"), expand = expansion(mult = 0.15)) +
  scale_y_continuous(labels = label_number(scale = 1e-6, suffix = "M"), expand = expansion(mult = 0.15)) +
  labs(title = "Profit vs shipping cost by category (bubble = sales)", x = "Total shipping cost", y = "Total net profit") +
  theme_minimal(base_size = 11) + theme(legend.position = "top", panel.grid.minor = element_blank())
plots <- list(shipdays_hist = p1, return_rate_segment = p2, shipdays_by_mode = p3, units_by_year = p4, sales_by_year = p5,
              returns_by_shipmode = p6, orderscore_hist = p7, margin_categories = p8, orders_by_category = p9, bubble_chart = p10)
for (nm in names(plots)) save_plot(plots[[nm]], paste0(nm, ".png"))
cat("Done. Figures in results/figures, tables in results/tables\n")

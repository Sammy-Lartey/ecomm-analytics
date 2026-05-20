import openpyxl
import csv
import os

src = "data/DataDNA Dataset Challenge - E-commerce Dataset - November 2025.xlsx"
os.makedirs("data/csv", exist_ok=True)

wb = openpyxl.load_workbook(src, read_only=True, data_only=True)

for sheet_name in ["Events", "Products", "Customers"]:
    ws = wb[sheet_name]
    out_path = f"data/csv/{sheet_name.lower()}.csv"
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        for row in ws.iter_rows(values_only=True):
            writer.writerow(row)
    print(f"Exported {sheet_name} → {out_path}")

wb.close()
print("Done.") 

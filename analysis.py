# === Tor exit hops: tables FIRST, then a clearer map (Colab) ===
# CSV expected headers: Timestamp, IP, Country  (Country is ISO-2 like DE, FR)
!pip -q install geopandas folium pycountry

import io, math
import pandas as pd
import geopandas as gpd
import folium
from folium.plugins import AntPath
import pycountry
from google.colab import files
from IPython.display import display

# ---------- 0) Upload ----------
print("Upload your tor-ip-log-YYYY-MM-DD.csv (Timestamp,IP,Country)...")
up = files.upload()
if not up:
    raise SystemExit("No file uploaded.")
csv_name = list(up.keys())[0]
df = pd.read_csv(io.BytesIO(up[csv_name]))

# ---------- 1) Clean / normalize ----------
df.columns = [c.strip().capitalize() for c in df.columns]
need = {"Timestamp","Ip","Country"}
if not need.issubset(df.columns):
    raise SystemExit(f"Missing required columns. Found: {df.columns.tolist()}  Needed: {sorted(need)}")

bad = {"FAILED","??","","NA","NAN",None}
df = df[~df["Country"].astype(str).str.upper().isin(bad)].copy()
df["Country"] = df["Country"].str.upper().str.strip()
# collapse consecutive duplicates (no movement)
df["__prev"] = df["Country"].shift(1)
df = df[df["Country"] != df["__prev"]].drop(columns="__prev").reset_index(drop=True)
if len(df) < 2:
    raise SystemExit("Not enough distinct country hops to draw routes (need at least 2 rows after cleaning).")

# ---------- 2) Build hop table ----------
hops_rows = []
for i in range(len(df)-1):
    hops_rows.append({
        "Step": i+1,
        "FromCountry": df.loc[i, "Country"],
        "ToCountry": df.loc[i+1, "Country"],
        "FromIP": df.loc[i, "Ip"],
        "ToIP": df.loc[i+1, "Ip"],
        "FromTime": df.loc[i, "Timestamp"],
        "ToTime": df.loc[i+1, "Timestamp"],
    })
hop_table = pd.DataFrame(hops_rows, columns=["Step","FromCountry","ToCountry","FromIP","ToIP","FromTime","ToTime"])

# country visit counts (after dedup)
visit_counts = df["Country"].value_counts().rename_axis("Country").reset_index(name="Visits")

# transition frequency
transitions = hop_table.groupby(["FromCountry","ToCountry"]).size().reset_index(name="Count")
transitions["Transition"] = transitions["FromCountry"] + " → " + transitions["ToCountry"]
transitions = transitions[["Transition","Count"]].sort_values("Count", ascending=False).reset_index(drop=True)

# ---------- 3) SHOW TABLES FIRST ----------
print("\n=== HOP TABLE ===")
display(hop_table)
print("\n=== COUNTRY VISIT COUNTS (deduped path) ===")
display(visit_counts)
print("\n=== TRANSITION FREQUENCIES ===")
display(transitions)

# ---------- 4) Map data (centroids) ----------
def iso2_to_iso3(iso2):
    try:
        return pycountry.countries.get(alpha_2=iso2).alpha_3
    except Exception:
        return None
df["ISO3"] = df["Country"].apply(iso2_to_iso3)
df = df[~df["ISO3"].isna()].reset_index(drop=True)

NE_URL = "https://naciscdn.org/naturalearth/110m/cultural/ne_110m_admin_0_countries.zip"
world = gpd.read_file(NE_URL)
iso3_col = [c for c in ["ISO_A3","ADM0_A3","ADMIN_A3"] if c in world.columns][0]
world["centroid"] = world.geometry.representative_point()
centroids = world.set_index(iso3_col)["centroid"]

# build hop coords
hops = []
for r in hops_rows:
    a_iso3 = iso2_to_iso3(r["FromCountry"])
    b_iso3 = iso2_to_iso3(r["ToCountry"])
    if a_iso3 in centroids.index and b_iso3 in centroids.index:
        pa, pb = centroids[a_iso3], centroids[b_iso3]
        hops.append({
            **r,
            "from_xy": (pa.y, pa.x),
            "to_xy": (pb.y, pb.x),
        })
if not hops:
    raise SystemExit("No drawable hops (centroids missing).")

# ---------- 5) Map (with red bullets at BOTH ends + centered step numbers) ----------
all_pts = [h["from_xy"] for h in hops] + [h["to_xy"] for h in hops]
clat = sum(p[0] for p in all_pts)/len(all_pts)
clon = sum(p[1] for p in all_pts)/len(all_pts)
m = folium.Map(location=[clat, clon], zoom_start=4, tiles="cartodbpositron")

# helper: step label (①..⑳ then [n])
ENCLOSED = "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳"
def step_icon(n): return ENCLOSED[n-1] if 1 <= n <= 20 else f"[{n}]"

# function to place label at precise 50% along the line
def midpoint(a, b):
    return ((a[0]+b[0])/2.0, (a[1]+b[1])/2.0)

for h in hops:
    a, b = h["from_xy"], h["to_xy"]
    latlngs = [a, b]
    tip = f"Step {h['Step']}: {h['FromCountry']} → {h['ToCountry']}"
    pop_html = (
        f"<b>Step {h['Step']}</b><br>"
        f"{h['FromCountry']} ({h['FromTime']}) → {h['ToCountry']} ({h['ToTime']})<br>"
        f"{h['FromIP']} → {h['ToIP']}"
    )
    pop = folium.Popup(html=pop_html, max_width=280)

    # line (keep AntPath but also a solid line so it's always visible)
    AntPath(latlngs, delay=650, dash_array=[10,20], weight=3, opacity=0.9).add_to(m)
    folium.PolyLine(latlngs, weight=2.5, opacity=0.85, tooltip=tip, popup=pop).add_to(m)

    # RED bullets at BOTH ends
    for endpoint, label in ((a, f"Start • {h['FromCountry']}"), (b, f"End • {h['ToCountry']}")):
        folium.CircleMarker(
            location=endpoint,
            radius=5,
            color="#d73027",  # red
            fill=True,
            fill_opacity=1.0,
            opacity=1.0,
            tooltip=label,
        ).add_to(m)

    # Step number centered ON the line, with high z-index
    mid = midpoint(a, b)
    folium.Marker(
        location=mid,
        tooltip=tip,
        z_index_offset=10000,
        icon=folium.DivIcon(html=f"""
          <div style="
              transform: translate(-50%, -50%);
              font-size:12px;font-weight:700;color:#1d1d1d;
              background:#ffffffee;padding:2px 6px;border-radius:8px;border:1px solid #777;">
            {step_icon(h['Step'])}
          </div>
        """),
    ).add_to(m)

# Optional: add country visit markers (small & grey so bullets stand out)
counts = df["Country"].value_counts().to_dict()
for iso2, count in counts.items():
    iso3 = iso2_to_iso3(iso2)
    if iso3 and iso3 in centroids:
        p = centroids[iso3]
        folium.CircleMarker(
            location=(p.y, p.x),
            radius=3 + min(count, 6),
            color="#555",
            fill=True, fill_opacity=0.5, opacity=0.5,
            tooltip=f"{iso2} (visits: {count})",
        ).add_to(m)

m.save("tor_hops_map.html")
print("\nSaved: tor_hops_map.html (download offered below)")
from google.colab import files; files.download("tor_hops_map.html")
m

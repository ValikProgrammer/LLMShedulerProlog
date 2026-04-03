"""
weather.py
Fetches the 5-day / 3-hour weather forecast for Paphos, Cyprus from OpenWeatherMap.
Returns both per-day summary (good/bad) and detailed 3-hour slots with temperature,
description, and condition for each slot.
Good weather: no rain, no thunderstorm, temperature > 12 C.
"""

import os
import requests
from datetime import datetime, timezone

OPENWEATHER_URL = "https://api.openweathermap.org/data/2.5/forecast"

# Weather condition codes that count as "bad" for outdoor activities
BAD_WEATHER_CODES = {
    # Thunderstorm
    200, 201, 202, 210, 211, 212, 221, 230, 231, 232,
    # Drizzle
    300, 301, 302, 310, 311, 312, 313, 314, 321,
    # Rain
    500, 501, 502, 503, 504, 511, 520, 521, 522, 531,
    # Snow
    600, 601, 602, 611, 612, 613, 615, 616, 620, 621, 622,
}

MIN_TEMPERATURE_C = 12.0  # below this, outdoor activities are not great

DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def _is_bad(weather_id: int, temp: float) -> bool:
    return (weather_id in BAD_WEATHER_CODES) or (temp < MIN_TEMPERATURE_C)


def get_detailed_forecast() -> dict:
    """
    Returns a dict like:
      {
        "monday": {
          "summary": "good",
          "slots": [
            {"hour": 9, "temp": 18.5, "description": "clear sky",
             "condition": "good", "icon": "01d", "wind": 3.2},
            ...
          ]
        },
        ...
      }
    Falls back to all "good" with empty slots if the API key is missing or call fails.
    """
    api_key = os.getenv("OPENWEATHERMAP_API_KEY", "")
    lat = float(os.getenv("WEATHER_LAT", "34.7757"))
    lon = float(os.getenv("WEATHER_LON", "32.4341"))

    if not api_key:
        return {day: {"summary": "good", "slots": []} for day in DAYS}

    try:
        resp = requests.get(
            OPENWEATHER_URL,
            params={
                "lat": lat,
                "lon": lon,
                "appid": api_key,
                "units": "metric",
                "cnt": 40,  # 5 days x 8 entries per day (every 3h)
            },
            timeout=5,
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception:
        return {day: {"summary": "good", "slots": []} for day in DAYS}

    today = datetime.now(timezone.utc).date()
    forecast: dict[str, dict] = {}

    for entry in data.get("list", []):
        dt = datetime.fromtimestamp(entry["dt"], tz=timezone.utc)
        delta = (dt.date() - today).days
        if delta < 0 or delta > 6:
            continue

        day_name = DAYS[(datetime.now(timezone.utc).weekday() + delta) % 7]

        if day_name not in forecast:
            forecast[day_name] = {"summary": "good", "slots": []}

        weather_id = entry["weather"][0]["id"]
        temp = entry["main"]["temp"]
        description = entry["weather"][0]["description"]
        icon = entry["weather"][0]["icon"]
        wind = entry.get("wind", {}).get("speed", 0)
        hour = dt.hour

        bad = _is_bad(weather_id, temp)
        condition = "bad" if bad else "good"

        forecast[day_name]["slots"].append({
            "hour": hour,
            "temp": round(temp, 1),
            "description": description,
            "condition": condition,
            "icon": icon,
            "wind": round(wind, 1),
        })

        # Day is bad if any slot is bad
        if bad:
            forecast[day_name]["summary"] = "bad"

    # Fill missing days
    for day in DAYS:
        if day not in forecast:
            forecast[day] = {"summary": "good", "slots": []}

    return forecast


def get_weekly_forecast() -> dict[str, str]:
    """
    Backward-compatible: returns { "monday": "good", ... }
    """
    detailed = get_detailed_forecast()
    return {day: info["summary"] for day, info in detailed.items()}


def detailed_to_weather_terms(detailed: dict) -> list[str]:
    """
    Converts detailed forecast to Prolog terms for slot-level weather checks:
      ["set_weather(monday, 9, good)", "set_weather(monday, 12, bad)", ...]
    Also includes day-level fallback terms:
      ["set_weather(monday, good)", ...]
    """
    terms = []
    for day, info in detailed.items():
        for slot in info["slots"]:
            terms.append(f"set_weather({day}, {slot['hour']}, {slot['condition']})")
        # Day-level fallback for days with no hourly data
        if not info["slots"]:
            terms.append(f"set_weather({day}, {info['summary']})")
    return terms

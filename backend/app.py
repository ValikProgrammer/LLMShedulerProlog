"""
app.py
Flask application — REST API for the Smart Scheduler web frontend.

Endpoints:
  GET  /api/schedule          Generate schedule for the current week
  POST /api/schedule/request  Parse NL request + regenerate schedule
  GET  /api/schedules/all     Return all valid schedule alternatives
  GET  /api/schedules/<n>     Return the n-th alternative (0-indexed)
  GET  /api/export/ical       Download .ics file for the current schedule
  GET  /api/stats             Return weekly statistics for the current schedule
  GET  /api/weather           Return current Paphos weather forecast
  GET  /api/base-schedule     Return the fixed university timetable
"""

import os
import json
import datetime
from pathlib import Path
from flask import Flask, jsonify, request, send_file, Response
from flask_cors import CORS
from dotenv import load_dotenv

load_dotenv()

from weather import get_detailed_forecast, detailed_to_weather_terms
from llm_parser import parse_weekly_request, constraints_to_prolog
from prolog_bridge import generate_schedule, all_schedules
from ical_export import schedule_to_ical

BASE_DIR = Path(__file__).parent.parent

app = Flask(__name__, static_folder=str(BASE_DIR / "frontend"), static_url_path="")
CORS(app)

# In-memory session state (single-user app)
_state = {
    "current_schedule": [],
    "previous_schedule": [],
    "previous_stats": {},
    "all_schedules": [],
    "current_index": 0,
    "warnings": [],
    "stats": {},
    "weather": {},
    "accumulated_terms": [],
}


# ===========================================================================
# HELPERS
# ===========================================================================

def _get_week_start() -> datetime.date:
    today = datetime.date.today()
    return today - datetime.timedelta(days=today.weekday())


def _refresh_schedule(llm_terms: list[str] | None = None):
    """Regenerate schedule using current weather + any extra LLM terms.
    llm_terms are stored separately from weather_terms to avoid doubling.
    """
    detailed = get_detailed_forecast()
    _state["weather"] = detailed

    weather_terms = detailed_to_weather_terms(detailed)

    if llm_terms is not None:
        _state["llm_terms"] = llm_terms

    # Combine: LLM constraints + fresh weather (never store weather in state)
    request_terms = (_state.get("llm_terms") or []) + weather_terms

    print(f"  WEATHER TERMS ({len(weather_terms)}): {weather_terms[:5]}{'...' if len(weather_terms) > 5 else ''}")
    print(f"  ALL TERMS TO PROLOG ({len(request_terms)})")

    result = generate_schedule(request_terms)
    _state["current_schedule"] = result["schedule"]
    _state["warnings"] = result["warnings"]
    _state["stats"] = result["stats"]
    _state["request_terms"] = request_terms   # for all_schedules on demand

    if result["warnings"]:
        print(f"  ⚠ WARNINGS: {result['warnings']}")
    print(f"  SCHEDULED {len(result['schedule'])} events")

    _state["all_schedules"] = []
    _state["current_index"] = 0


# ===========================================================================
# ROUTES — Pages
# ===========================================================================

@app.route("/")
def index():
    return app.send_static_file("index.html")


# ===========================================================================
# ROUTES — API
# ===========================================================================

@app.route("/api/weather", methods=["GET"])
def api_weather():
    """Return the current Paphos weather forecast with hourly detail."""
    detailed = get_detailed_forecast()
    _state["weather"] = detailed
    return jsonify({"forecast": detailed})


@app.route("/api/schedule", methods=["GET"])
def api_schedule():
    """
    Generate the schedule for the current week using the base knowledge base
    and the current weather forecast. No NL request needed.
    """
    _refresh_schedule()
    return jsonify({
        "schedule": _state["current_schedule"],
        "warnings": _state["warnings"],
        "stats":    _state["stats"],
        "count":    len(_state["all_schedules"]),
        "index":    _state["current_index"],
    })


@app.route("/api/schedule/request", methods=["POST"])
def api_schedule_request():
    """
    Accept a natural-language weekly request, parse it with Claude Haiku,
    and regenerate the schedule with the accumulated constraints.

    Constraints are accumulated across requests — each new request adds to
    the existing set. Use POST /api/schedule/reset to start fresh.

    Request body: { "message": "I have a DM deadline on Thursday, want tennis Wed" }
    """
    body = request.get_json(silent=True) or {}
    message = body.get("message", "").strip()

    if not message:
        return jsonify({"error": "No message provided"}), 400

    # Parse with LLM
    constraints = parse_weekly_request(message)
    new_terms = constraints_to_prolog(constraints)

    # Accumulate: merge new terms with existing ones
    existing_terms = _state.get("accumulated_terms", [])
    merged_terms = existing_terms + new_terms
    _state["accumulated_terms"] = merged_terms

    print(f"\n{'='*60}")
    print(f"USER MESSAGE: {message}")
    print(f"{'='*60}")
    print(f"NEW CONSTRAINTS ({len(constraints)}):")
    for c in constraints:
        print(f"  {c}")
    print(f"NEW PROLOG TERMS ({len(new_terms)}):")
    for t in new_terms:
        print(f"  {t}")
    print(f"ACCUMULATED TERMS ({len(merged_terms)}):")
    for t in merged_terms:
        print(f"  {t}")
    print(f"{'='*60}\n")

    # Save current schedule as "before" for comparison
    _state["previous_schedule"] = list(_state["current_schedule"])
    _state["previous_stats"] = dict(_state["stats"])

    _refresh_schedule(merged_terms)

    return jsonify({
        "parsed_constraints": constraints,
        "prolog_terms": new_terms,
        "accumulated_terms": merged_terms,
        "schedule":  _state["current_schedule"],
        "previous_schedule": _state["previous_schedule"],
        "warnings":  _state["warnings"],
        "stats":     _state["stats"],
        "previous_stats": _state["previous_stats"],
        "count":     len(_state["all_schedules"]),
        "index":     _state["current_index"],
    })


@app.route("/api/schedule/reset", methods=["POST"])
def api_schedule_reset():
    """Reset all accumulated LLM constraints and regenerate a clean schedule."""
    _state["accumulated_terms"] = []
    _refresh_schedule([])
    print("  ♻ RESET: all accumulated constraints cleared")
    return jsonify({
        "schedule":  _state["current_schedule"],
        "warnings":  _state["warnings"],
        "stats":     _state["stats"],
        "count":     0,
        "index":     0,
    })


@app.route("/api/schedules/all", methods=["GET"])
def api_schedules_all():
    """
    Compute all schedule alternatives (lazy — only runs when first requested).
    Returns metadata: count and current index.
    """
    if not _state["all_schedules"]:
        terms = _state.get("request_terms") or []
        result = all_schedules(terms)
        _state["all_schedules"] = result["schedules"]

    return jsonify({
        "count": len(_state["all_schedules"]),
        "index": _state["current_index"],
    })


@app.route("/api/schedules/<int:index>", methods=["GET"])
def api_schedule_by_index(index: int):
    """Return a specific schedule alternative by index (0-based). Computes all on first call."""
    if not _state["all_schedules"]:
        terms = _state.get("request_terms") or []
        result = all_schedules(terms)
        _state["all_schedules"] = result["schedules"]

    schedules = _state["all_schedules"]
    if not schedules:
        return jsonify({"error": "No schedule alternatives found."}), 404
    if index < 0 or index >= len(schedules):
        return jsonify({"error": f"Index out of range. Available: 0-{len(schedules)-1}"}), 404

    _state["current_index"] = index
    return jsonify({
        "schedule": schedules[index],
        "index": index,
        "count": len(schedules),
    })


@app.route("/api/export/ical", methods=["GET"])
def api_export_ical():
    """Download the current schedule as a .ics file (Google Calendar compatible)."""
    schedule = _state["current_schedule"]
    if not schedule:
        return jsonify({"error": "No schedule to export. Generate one first."}), 404

    week_start = _get_week_start()
    ical_bytes = schedule_to_ical(schedule, week_start)

    week_str = week_start.strftime("%Y-W%W")
    return Response(
        ical_bytes,
        mimetype="text/calendar",
        headers={
            "Content-Disposition": f'attachment; filename="schedule-{week_str}.ics"'
        },
    )


@app.route("/api/stats", methods=["GET"])
def api_stats():
    """Return weekly statistics for the current schedule."""
    return jsonify(_state["stats"])


# ===========================================================================
# ENTRY POINT
# ===========================================================================

if __name__ == "__main__":
    port = int(os.getenv("FLASK_PORT", 5000))
    debug = os.getenv("FLASK_DEBUG", "false").lower() == "true"

    print(f"Smart Scheduler running at http://localhost:{port}")
    print("Make sure SWI-Prolog is installed: swipl --version")

    # threaded=False: pyswip is not thread-safe — one Prolog query at a time.
    app.run(host="0.0.0.0", port=port, debug=debug, threaded=False)

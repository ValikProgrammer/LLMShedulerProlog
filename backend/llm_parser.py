"""
llm_parser.py
Uses Claude Haiku to parse a natural-language weekly request into a list of
structured Prolog-compatible constraint terms.

Supported output terms:
  add_task(id, activity, duration_minutes)
  add_deadline(activity, days_until)
  add_oneoff(id, label, day, start_hour, duration_minutes, priority)
  set_weather(day, good|bad)        -- manual override
  skip_activity(activity)           -- skip this week
"""

import os
import json
import anthropic

SYSTEM_PROMPT = """You are a scheduling assistant. Parse the user's weekly planning request into structured JSON.

Return ONLY a JSON array of constraint objects. No explanation, no markdown, just the JSON array.

IMPORTANT: The scheduler already has a full base schedule with weekly tasks:
  ma_hw (2x2h), ma_theory (1h), la_hw (2x2h), dm_tasks (2h+1h), dm_theory (2h+1h),
  algo_hw (2h), kotlin_hw (1.5h+1h), kotlin_lecture (1.5h), prog_hw (1.5h), te_jb_hw (1.5h),
  gym (3x1h), food_after_gym (3x30min), tennis (2x1.5h)

Do NOT re-add tasks that already exist in the base schedule. Only use constraints to MODIFY the default behavior.

Supported constraint types:

1. {"type": "skip_activity", "activity": "activity_name"}
   Skip ALL sessions of this activity this week. Use when user says "skip gym", "no tennis this week".

2. {"type": "add_deadline", "activity": "activity_name", "days_until": N}
   Boost priority for deadline. days_until = 0 means today, 1 = tomorrow, etc.

3. {"type": "pin_to_day", "activity": "activity_name", "day": "monday"}
   Force one session of this activity to a specific day. Use for "I want gym on Wednesday",
   "put DM theory on Saturday". Only pins one session — other sessions stay flexible.

4. {"type": "avoid_day", "activity": "activity_name", "day": "thursday"}
   Prevent scheduling this activity on a specific day. Use for "no math on Friday",
   "don't put gym on Wednesday".

5. {"type": "set_priority", "activity": "activity_name", "priority": N}
   Override priority (1-10). Use for "make algo HW more important" → priority 9.

6. {"type": "add_oneoff", "id": "unique_id", "label": "Human Label", "day": "monday",
    "start_hour": null, "duration_minutes": N, "priority": N}
   Add a NEW one-time event not in the base schedule. Set start_hour to null if flexible,
   or a decimal like 10.5 for 10:30. Use for meetings, appointments, custom events.
   Also use for tennis/gym on unusual days (e.g. tennis on Tuesday — not a normal buddy day).

7. {"type": "add_task", "id": "unique_id", "activity": "activity_name", "duration_minutes": N}
   Add an EXTRA session of an existing activity beyond the weekly budget.

Valid activity names: ma_hw, ma_theory, la_hw, dm_tasks, dm_theory, algo_hw,
   kotlin_hw, kotlin_lecture, prog_hw, te_jb_hw, gym, tennis, hike,
   the_hub, mafia, migration_office, food_after_gym

Day names (lowercase): monday, tuesday, wednesday, thursday, friday, saturday, sunday

Examples:
- "Move DM theory from Thursday to Saturday" →
  [{"type": "pin_to_day", "activity": "dm_theory", "day": "saturday"},
   {"type": "avoid_day", "activity": "dm_theory", "day": "thursday"}]

- "I want gym on Monday, Wednesday, Friday" →
  [{"type": "pin_to_day", "activity": "gym", "day": "monday"},
   {"type": "pin_to_day", "activity": "gym", "day": "wednesday"},
   {"type": "pin_to_day", "activity": "gym", "day": "friday"}]
  (Note: only first pin takes effect; others hint preference via avoid)

- "Add tennis on Tuesday" →
  [{"type": "add_oneoff", "id": "tennis_tue", "label": "Tennis", "day": "tuesday", "start_hour": null, "duration_minutes": 90, "priority": 5}]

- "No math on Friday" →
  [{"type": "avoid_day", "activity": "ma_hw", "day": "friday"},
   {"type": "avoid_day", "activity": "la_hw", "day": "friday"},
   {"type": "avoid_day", "activity": "dm_tasks", "day": "friday"}]

- "DM deadline on Thursday" →
  [{"type": "add_deadline", "activity": "dm_tasks", "days_until": 3}]

- "Skip gym this week" → [{"type": "skip_activity", "activity": "gym"}]

- "Make algo HW high priority" → [{"type": "set_priority", "activity": "algo_hw", "priority": 9}]

- "Meeting with advisor Tuesday 14:00, 1 hour" →
  [{"type": "add_oneoff", "id": "advisor_tue", "label": "Advisor Meeting", "day": "tuesday", "start_hour": 14.0, "duration_minutes": 60, "priority": 8}]

Return [] if the request contains nothing schedulable."""

# Today's day names for deadline calculation
import datetime

DAY_NAMES = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def _days_until(day_name: str) -> int:
    today = datetime.date.today().weekday()  # 0=Monday
    target = DAY_NAMES.index(day_name.lower())
    delta = (target - today) % 7
    return delta if delta > 0 else 7  # if today, treat as next week


def parse_weekly_request(user_message: str) -> list[dict]:
    """
    Send the user's natural language request to Claude Haiku.
    Returns a list of parsed constraint dicts.
    """
    api_key = os.getenv("ANTHROPIC_API_KEY", "")
    if not api_key:
        return []

    client = anthropic.Anthropic(api_key=api_key)

    # Inject today's date so the model can resolve "Thursday" → days_until
    today_name = DAY_NAMES[datetime.date.today().weekday()]
    date_context = f"Today is {today_name}, {datetime.date.today().isoformat()}."

    message = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=512,
        system=SYSTEM_PROMPT,
        messages=[
            {"role": "user", "content": f"{date_context}\n\n{user_message}"}
        ],
    )

    raw = message.content[0].text.strip()

    try:
        constraints = json.loads(raw)
        if not isinstance(constraints, list):
            return []
        return constraints
    except json.JSONDecodeError:
        # Try to extract JSON array from the response if there's extra text
        import re
        match = re.search(r"\[.*\]", raw, re.DOTALL)
        if match:
            try:
                return json.loads(match.group())
            except json.JSONDecodeError:
                pass
        return []


_KNOWN_ACTIVITIES = {
    "tennis", "gym", "hike", "mafia", "the_hub", "migration_office",
    "food_after_gym",
    "ma_hw", "ma_theory", "la_hw", "dm_tasks", "dm_theory",
    "algo_hw", "kotlin_hw", "kotlin_lecture", "prog_hw", "te_jb_hw",
}

# Map common label variations to their Prolog atom names.
_LABEL_MAP = {
    "tennis": "tennis", "gym": "gym", "hike": "hike",
    "mafia": "mafia", "the hub": "the_hub",
    "migration office": "migration_office",
    "ma homework": "ma_hw", "ma hw": "ma_hw", "math analysis hw": "ma_hw",
    "la homework": "la_hw", "la hw": "la_hw", "linear algebra hw": "la_hw",
    "dm hw": "dm_tasks", "dm tasks": "dm_tasks", "discrete math hw": "dm_tasks",
    "dm theory": "dm_theory",
    "algo hw": "algo_hw", "algorithms hw": "algo_hw", "algorithms": "algo_hw",
    "kotlin hw": "kotlin_hw", "kotlin homework": "kotlin_hw",
    "kotlin lecture": "kotlin_lecture",
    "prog hw": "prog_hw", "prog homework": "prog_hw",
    "te/jb hw": "te_jb_hw", "tejb hw": "te_jb_hw", "te jb hw": "te_jb_hw",
    "te/jb homework": "te_jb_hw",
}


def _label_to_activity(label: str, fallback_id: str) -> str:
    """Resolve a human-readable label to a Prolog KB activity atom."""
    low = label.lower().strip()
    # Direct match in label map
    if low in _LABEL_MAP:
        return _LABEL_MAP[low]
    # Already a known activity atom (e.g. LLM returned 'tennis' directly)
    if low in _KNOWN_ACTIVITIES:
        return low
    # Fallback: use the id as-is (novel one-off task)
    return fallback_id


def constraints_to_prolog(constraints: list[dict]) -> list[str]:
    """
    Convert parsed constraint dicts to Prolog term strings.
    These are passed to the Prolog scheduler via pyswip.
    """
    terms = []
    for c in constraints:
        ctype = c.get("type")

        if ctype == "add_task":
            terms.append(
                f"add_task({c['id']}, {c['activity']}, {c['duration_minutes']})"
            )

        elif ctype == "add_deadline":
            terms.append(
                f"add_deadline({c['activity']}, {c['days_until']})"
            )

        elif ctype == "add_oneoff":
            start = c.get("start_hour")
            start_str = str(start) if start is not None else "flexible"
            activity = _label_to_activity(c.get("label", ""), c.get("id", ""))
            terms.append(
                f"add_oneoff({c['id']}, {activity}, {c['day']}, "
                f"{start_str}, {c['duration_minutes']}, {c['priority']})"
            )

        elif ctype == "skip_activity":
            terms.append(f"skip_activity({c['activity']})")

        elif ctype == "pin_to_day":
            terms.append(f"pin_to_day({c['activity']}, {c['day']})")

        elif ctype == "avoid_day":
            terms.append(f"avoid_day({c['activity']}, {c['day']})")

        elif ctype == "set_priority":
            terms.append(f"set_priority({c['activity']}, {c['priority']})")

    return terms

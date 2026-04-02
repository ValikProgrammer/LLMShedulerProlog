# Smart Scheduler

A personal weekly schedule planner that combines **SWI-Prolog constraint logic (CLP(FD))** with **LLM natural language input** and **live weather data** to automatically generate optimal weekly schedules.

Built as a Programming Paradigms (Prolog) university project.

---

## Overview

Every week you describe what you need in plain English:

> *"This week I have a DM deadline on Thursday, want tennis on Wednesday and Friday, and need to go to the migration office Tuesday morning."*

Claude Haiku parses this into Prolog constraints. SWI-Prolog then finds a valid schedule that satisfies all rules — fitting homework, gym, tennis, and personal tasks around your fixed university timetable. The result is displayed in a Google Calendar–style web UI and can be exported as `.ics`.

---

## Architecture

```
Browser (FullCalendar.js)
        │  REST API
   Flask (Python)
    ├── pyswip ──► SWI-Prolog (CLP(FD) scheduler)
    ├── Anthropic SDK ──► Claude Haiku (NL → constraints)
    └── OpenWeatherMap API (Paphos forecast)
```

**Why Prolog?**
Prolog's CLP(FD) library expresses scheduling constraints declaratively — `all_different`, priority orderings, incompatibility rules — without writing a search algorithm. `findall/3` enumerates *all* valid schedules, enabling the Next/Prev navigation feature. The same code that checks one schedule checks all of them.

**Why LLM?**
Natural language is flexible. "I have a deadline Thursday" and "DM homework is due in 2 days" mean the same thing. Claude Haiku translates arbitrary phrasing into structured Prolog facts, while Prolog guarantees the answer is logically consistent with all constraints.

---

## Features

| Feature | Description |
|---|---|
| **Fixed university timetable** | 11 locked blocks per week, never moved |
| **Automatic HW scheduling** | Weekly time budgets per subject, split into ≤2h sessions |
| **Priority-based conflict resolution** | If time runs out, lower-priority events are dropped first |
| **Weather-aware** | Tennis and hiking only scheduled when Paphos forecast is good |
| **Tennis buddy** | Dmitri's availability constrains tennis slots |
| **Energy model** | No heavy cognitive tasks within 90min of gym, 180min of hiking |
| **Deadline boost** | Mention a deadline → that task's priority temporarily rises to 9 |
| **Session splitting** | Tasks >2h automatically split into multiple blocks |
| **Next / Prev** | Browse all valid schedules found by Prolog |
| **iCal export** | One-click `.ics` download → import into Google Calendar |
| **Weekly stats** | University time, study time, physical activity, free time |
| **LLM input** | Weekly requests in plain English |

---

## Fixed University Schedule

These blocks are hardcoded and never moved by the scheduler:

| Day | Time | Subject |
|---|---|---|
| Monday | 09:00–10:30 | Math Analysis |
| Monday | 12:00–15:00 | Programming Paradigms G1 |
| Tuesday | 12:00–15:00 | Algorithms AI Lab |
| Wednesday | 09:00–12:00 | Kotlin G5 |
| Wednesday | 12:00–15:00 | Linear Algebra AI Lab |
| Wednesday | 18:15–21:15 | JB Horizons (TE) |
| Thursday | 09:00–12:00 | Discrete Math G2 |
| Thursday | 12:00–12:40 | Discrete Upsolve |
| Thursday | 15:00–18:00 | Project Seminar |
| Friday | 09:00–10:30 | Math Analysis |
| Saturday | 10:30–12:00 | Math Analysis |

Semi-fixed (student-taught, priority 6):

| Day | Time | Subject |
|---|---|---|
| Friday | 15:00–17:00 | LA++ |

---

## Priority System (1–10)

Priorities determine what gets dropped when the week is too full.

| Priority | Activities |
|---|---|
| **10** | Migration office, critical admin |
| **9** | Deadline-boosted tasks (max boost) |
| **8** | MA HW, LA HW, university classes (MA/LA/Algo/Kotlin/Prog/ProjectSeminar/JB) |
| **7** | Math self-study (MA theory) |
| **6** | DM tasks, Kotlin HW, Prog HW, Discrete Math class, LA++ |
| **5** | DM theory, Algo HW, TE/JB HW, Kotlin lecture, Gym |
| **4** | Tennis |
| **2** | Hike, The HUB |
| **1** | Mafia, social errands |

---

## Constraints

### Hard (never violated)
- Sleep block: **00:00–08:20** every day
- University fixed blocks: cannot be moved or overwritten
- No event overlap

### Physical incompatibilities (same day)
- `hike` + `gym` → incompatible
- `hike` + `tennis` → incompatible
- `gym` + `tennis` → incompatible

### Recovery time (no heavy cognitive tasks after)
- After gym: **90 minutes** rest
- After hike: **180 minutes** rest

### Post-gym food
- Food block required within **2 hours** after gym

### Weather (Paphos, Cyprus — OpenWeatherMap)
- Tennis: requires good weather
- Hike: requires good weather

### Tennis buddy — Dmitri
- Available: Monday, Wednesday, Friday — 16:00–20:00
- Unavailable: Thursday (works), Sunday (family)

### Daily cognitive limits (soft — warning if violated, not hard block)
- Math: ≤ 4h/day
- Programming: ≤ 5h/day

### Session duration
- Maximum single session: **2 hours**
- No minimum (e.g. Discrete Upsolve = 40 min is fine)
- Tasks with budget >2h are split into multiple ≤2h blocks

### Deadline boost
- If a task has a deadline within 2 days: priority boosted by +3 (capped at 9)
- Boost lasts one planning cycle only

---

## Weekly Budget (flexible tasks Prolog schedules)

| Subject | Sessions | Total/week |
|---|---|---|
| Math Analysis | 1h theory + 2 × 2h HW | ~5h |
| Discrete Math | 3h tasks + 3h theory | ~6h |
| Linear Algebra | 4h HW | ~4h |
| Kotlin | 2.5h HW + optional lecture | ~4h |
| Prog Paradigms | 1.5h HW | ~1.5h |
| Algorithms | 2h HW | ~2h |
| TE / JB Horizons | 1.5h HW | ~1.5h |
| Gym | 3×/week + food after | ~7.5h |
| Tennis | 2×/week, 16:00–20:00 | ~3h |

---

## How Weekly Planning Works

1. **Base semester schedule** — university blocks are loaded from `data/base_schedule.json` once
2. **Weekly request** — you type in plain English what you need this week
3. **LLM parsing** — Claude Haiku converts your message to Prolog constraint facts
4. **Scheduling** — Prolog finds all valid arrangements, ranked by priority score
5. **Display** — first solution shown; use Next/Prev to browse alternatives
6. **Export** — download `.ics` to import into Google Calendar

---

## Project Structure

```
smart-scheduler/
├── README.md
├── requirements.txt
├── .env.example
├── prolog/
│   ├── knowledge_base.pl   # facts: activities, priorities, budgets, buddies
│   ├── constraints.pl      # rules: incompatibilities, recovery, weather
│   ├── scheduler.pl        # CLP(FD) main scheduler + findall
│   └── utils.pl            # time arithmetic helpers
├── backend/
│   ├── app.py              # Flask routes
│   ├── prolog_bridge.py    # pyswip interface
│   ├── llm_parser.py       # Claude Haiku → Prolog facts
│   ├── weather.py          # OpenWeatherMap API
│   └── ical_export.py      # .ics file generation
├── frontend/
│   ├── index.html
│   ├── css/style.css
│   └── js/
│       ├── calendar.js     # FullCalendar initialisation
│       └── app.js          # API calls, UI logic
└── data/
    ├── base_schedule.json  # fixed university blocks
    ├── priorities.json     # priority table
    └── weekly_budgets.json # time budgets per subject
```

---

## Setup

### Option A — Docker (recommended)

**Requirements:** Docker + Docker Compose

```bash
cp .env.example .env
# fill in ANTHROPIC_API_KEY and OPENWEATHERMAP_API_KEY in .env

docker compose up --build
```

Open `http://localhost:5000`

SWI-Prolog is installed automatically inside the container. No local Prolog installation needed.

To stop:
```bash
docker compose down
```

To rebuild after code changes:
```bash
docker compose up --build
```

---

### Option B — Local

**Requirements:**
- SWI-Prolog (`sudo pacman -S swi-prolog` on Manjaro / `sudo apt install swi-prolog` on Debian)
- Python 3.10+
- OpenWeatherMap API key (free tier)
- Anthropic API key

```bash
pip install -r requirements.txt
cp .env.example .env
# fill in ANTHROPIC_API_KEY and OPENWEATHERMAP_API_KEY
python backend/app.py
```

Open `http://localhost:5000`

---

## Detailed Technical Notes

### CLP(FD) Scheduling

The core scheduler represents each flexible task as a set of time-slot variables with domains `1..N` (where N = total 30-minute slots in the week). Constraints are posted:

```prolog
all_different(Slots),          % no overlap
domain_bounds(Slots, Tasks),   % respect fixed university blocks
priority_order(Tasks, Slots),  % higher priority → scheduled first
weather_check(Tasks, Slots),   % outdoor tasks need good forecast
labeling([ff, up], Slots)      % first-fail + ascending value heuristic
```

`findall(Schedule, schedule(Tasks, Schedule), All)` collects every valid solution for Next/Prev browsing.

### Session Splitting

A task with a 4-hour weekly budget is represented as two separate task instances of 2h each. Prolog treats them as independent events with the same subject label but different slot variables.

### Deadline Boost

```prolog
effective_priority(Task, P) :-
    task_priority(Task, Base),
    ( deadline_within(Task, 2) ->
        P is min(Base + 3, 9)
    ;   P = Base
    ).
```

### Priority-Based Dropping

When no full solution exists, the scheduler iteratively relaxes lower-priority soft constraints:

1. Remove priority ≤ 1 tasks
2. Still no solution → remove priority ≤ 2
3. Continue until solution found
4. Report which tasks were dropped as warnings in the UI
# LLMShedulerProlog

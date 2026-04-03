/**
 * app.js
 * Smart Scheduler — frontend logic.
 * Handles:
 *  - FullCalendar initialisation
 *  - API communication with Flask backend
 *  - LLM weekly request submission
 *  - Next / Prev navigation between schedule alternatives
 *  - iCal export
 *  - Stats panel
 *  - Weather panel
 *  - Warnings panel
 */

const API = "http://localhost:5000/api";

// ===== STATE =====
let calendar = null;
let currentScheduleIndex = 0;
let totalScheduleCount = 0;
let currentScheduleData = null;  // raw schedule array for JSON copy
let previousSchedule = null;
let previousStats = null;
let currentStatsData = null;
let showingBefore = false;

// ===== DOM REFS =====
const llmInput       = document.getElementById("llm-input");
const btnRequest     = document.getElementById("btn-request");
const btnReset       = document.getElementById("btn-reset");
const btnGenerate    = document.getElementById("btn-generate");
const btnExport      = document.getElementById("btn-export");
const btnCopyJson    = document.getElementById("btn-copy-json");
const btnPrev        = document.getElementById("btn-prev");
const btnNext        = document.getElementById("btn-next");
const altCounter     = document.getElementById("alt-counter");
const loadingOverlay = document.getElementById("loading-overlay");
const loadingMsg     = document.getElementById("loading-msg");

// ===== INIT =====
document.addEventListener("DOMContentLoaded", () => {
  initCalendar();
  loadWeather();
  generateSchedule();
  bindEvents();
});

// ===== CALENDAR INIT =====
function initCalendar() {
  const el = document.getElementById("calendar");

  calendar = new FullCalendar.Calendar(el, {
    initialView: "timeGridWeek",
    firstDay: 1,         // week starts Monday
    allDaySlot: false,
    slotMinTime: "08:00:00",
    slotMaxTime: "24:00:00",
    slotDuration: "00:30:00",
    snapDuration: "00:30:00",
    height: "100%",
    headerToolbar: {
      left:   "prev,next today",
      center: "title",
      right:  "timeGridWeek,timeGridDay",
    },
    eventTimeFormat: {
      hour:   "2-digit",
      minute: "2-digit",
      hour12: false,
    },
    eventClick: handleEventClick,
    eventDidMount: styleEvent,
  });

  calendar.render();
}

// ===== BIND UI EVENTS =====
function bindEvents() {
  btnRequest.addEventListener("click", submitWeeklyRequest);
  btnReset.addEventListener("click", resetConstraints);
  btnGenerate.addEventListener("click", generateSchedule);
  btnExport.addEventListener("click", exportIcal);
  btnCopyJson.addEventListener("click", copyScheduleJson);
  btnPrev.addEventListener("click", () => navigateSchedule(-1));
  btnNext.addEventListener("click", () => navigateSchedule(+1));

  document.getElementById("btn-before").addEventListener("click", () => toggleCompare(true));
  document.getElementById("btn-after").addEventListener("click", () => toggleCompare(false));

  llmInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && e.ctrlKey) submitWeeklyRequest();
  });
}

function toggleCompare(showBefore) {
  showingBefore = showBefore;
  document.getElementById("btn-before").classList.toggle("active", showBefore);
  document.getElementById("btn-after").classList.toggle("active", !showBefore);

  if (showBefore && previousSchedule) {
    renderEvents(previousSchedule);
    if (previousStats) renderStats(previousStats);
  } else if (currentScheduleData) {
    renderEvents(currentScheduleData);
    if (currentStatsData) renderStats(currentStatsData);
  }
}

// ===== API CALLS =====

async function generateSchedule() {
  showLoading("Generating schedule with Prolog...");
  try {
    const res = await fetch(`${API}/schedule`);
    const data = await res.json();
    handleScheduleResponse(data);
  } catch (err) {
    showError("Could not connect to the backend. Is Flask running?");
  } finally {
    hideLoading();
  }
}

async function submitWeeklyRequest() {
  const message = llmInput.value.trim();
  if (!message) return;

  showLoading("Claude Haiku is parsing your request...");
  btnRequest.disabled = true;

  try {
    const res = await fetch(`${API}/schedule/request`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message }),
    });
    const data = await res.json();

    if (data.error) {
      showError(data.error);
      return;
    }

    // Store previous schedule for Before/After comparison
    if (data.previous_schedule && data.previous_schedule.length > 0) {
      previousSchedule = data.previous_schedule;
      previousStats = data.previous_stats || null;
      showingBefore = false;
      document.getElementById("compare-section").style.display = "flex";
      document.getElementById("btn-before").classList.remove("active");
      document.getElementById("btn-after").classList.add("active");
    }

    // Show parsed constraints
    renderConstraints(data.parsed_constraints || []);
    handleScheduleResponse(data);
  } catch (err) {
    showError("Request failed. Check the backend logs.");
  } finally {
    hideLoading();
    btnRequest.disabled = false;
  }
}

async function resetConstraints() {
  showLoading("Resetting all constraints...");
  try {
    const res = await fetch(`${API}/schedule/reset`, { method: "POST" });
    const data = await res.json();
    handleScheduleResponse(data);
    renderConstraints([]);
    llmInput.value = "";
  } catch (err) {
    showError("Reset failed.");
  } finally {
    hideLoading();
  }
}

async function navigateSchedule(delta) {
  // First click: load all schedule alternatives from Prolog
  if (totalScheduleCount === 0) {
    showLoading("Finding all schedule alternatives (Prolog findall)...");
    try {
      const res = await fetch(`${API}/schedules/all`);
      const data = await res.json();
      totalScheduleCount = data.count || 0;
      currentScheduleIndex = data.index || 0;
      updateAltCounter();
      if (totalScheduleCount === 0) {
        showError("No schedule alternatives found.");
        return;
      }
    } catch (err) {
      showError("Could not load alternatives.");
      return;
    } finally {
      hideLoading();
    }
  }

  const newIndex = currentScheduleIndex + delta;
  if (newIndex < 0 || newIndex >= totalScheduleCount) return;

  showLoading(`Loading schedule ${newIndex + 1} of ${totalScheduleCount}...`);
  try {
    const res = await fetch(`${API}/schedules/${newIndex}`);
    const data = await res.json();
    currentScheduleIndex = data.index;
    currentScheduleData = data.schedule || [];
    renderEvents(currentScheduleData);
    updateAltCounter();
  } catch (err) {
    showError("Could not load alternative.");
  } finally {
    hideLoading();
  }
}

async function loadWeather() {
  try {
    const res = await fetch(`${API}/weather`);
    const data = await res.json();
    renderWeather(data.forecast || {});
  } catch {
    document.getElementById("weather-panel").innerHTML =
      '<p class="loading-text">Weather unavailable</p>';
  }
}

function exportIcal() {
  window.location.href = `${API}/export/ical`;
}

async function copyScheduleJson() {
  if (!currentScheduleData) return;
  const json = JSON.stringify(currentScheduleData, null, 2);
  try {
    await navigator.clipboard.writeText(json);
    const label = document.getElementById("btn-copy-json-text");
    label.textContent = "Copied!";
    setTimeout(() => { label.textContent = "Copy JSON"; }, 1500);
  } catch {
    // Fallback for non-HTTPS / older browsers
    const ta = document.createElement("textarea");
    ta.value = json;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
    const label = document.getElementById("btn-copy-json-text");
    label.textContent = "Copied!";
    setTimeout(() => { label.textContent = "Copy JSON"; }, 1500);
  }
}

// ===== RENDER =====

function handleScheduleResponse(data) {
  currentScheduleData = data.schedule || [];
  currentStatsData = data.stats || {};
  renderEvents(currentScheduleData);
  renderStats(currentStatsData);
  renderWarnings(data.warnings || []);
  btnCopyJson.style.display = currentScheduleData.length > 0 ? "" : "none";

  totalScheduleCount = data.count || 0;
  currentScheduleIndex = data.index || 0;
  updateAltCounter();
}

function renderEvents(events) {
  calendar.removeAllEvents();

  const fcEvents = events.map(ev => ({
    title:           ev.label || formatSubject(ev.subject),
    start:           dayTimeToISO(ev.day, ev.start),
    end:             dayTimeToISO(ev.day, ev.end),
    backgroundColor: ev.color || "#9E9E9E",
    borderColor:     "transparent",
    textColor:       contrastColor(ev.color || "#9E9E9E"),
    extendedProps: {
      subject:  ev.subject,
      type:     ev.type,
      color:    ev.color,
    },
    classNames: [ev.type === "fixed" ? "fixed-event" : "flexible-event"],
  }));

  calendar.addEventSource(fcEvents);
}

function styleEvent(info) {
  // Darken border-left slightly to indicate event type
  const type = info.event.extendedProps.type;
  if (type === "fixed") {
    info.el.style.borderLeft = `3px solid rgba(255,255,255,0.4)`;
  } else if (type === "semi_fixed") {
    info.el.style.borderLeft = `3px solid rgba(255,255,255,0.25)`;
    info.el.style.opacity = "0.9";
  }
}

function handleEventClick(info) {
  const props = info.event.extendedProps;
  const msg = [
    `Subject: ${info.event.title}`,
    `Type: ${props.type}`,
    `Day: ${info.event.start.toLocaleDateString("en-US", { weekday: "long" })}`,
    `Time: ${formatTime(info.event.start)} – ${formatTime(info.event.end)}`,
  ].join("\n");
  alert(msg);
}

function renderStats(stats) {
  const fmt = mins => {
    if (!mins) return "—";
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return m > 0 ? `${h}h ${m}m` : `${h}h`;
  };

  document.getElementById("stat-uni").textContent      = fmt(stats.university_minutes);
  document.getElementById("stat-study").textContent    = fmt(stats.study_minutes);
  document.getElementById("stat-physical").textContent = fmt(stats.physical_minutes);
  document.getElementById("stat-sleep").textContent    = fmt(stats.sleep_minutes);
  document.getElementById("stat-free").textContent     = fmt(stats.free_minutes);
}

function renderWarnings(warnings) {
  const section = document.getElementById("warnings-section");
  const list    = document.getElementById("warnings-list");

  if (!warnings || warnings.length === 0) {
    section.style.display = "none";
    return;
  }

  section.style.display = "flex";
  list.innerHTML = warnings
    .map(w => `<div class="warning-item">${escapeHtml(w)}</div>`)
    .join("");
}

function renderConstraints(constraints) {
  const section = document.getElementById("constraints-section");
  const list    = document.getElementById("constraints-list");

  if (!constraints || constraints.length === 0) {
    section.style.display = "none";
    return;
  }

  section.style.display = "flex";
  list.innerHTML = constraints
    .map(c => `<div class="constraint-tag">${escapeHtml(JSON.stringify(c))}</div>`)
    .join("");
}

function renderWeather(forecast) {
  const panel = document.getElementById("weather-panel");
  const days  = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
  const condIcon = { good: "☀️", bad: "🌧️" };

  panel.innerHTML = days.map(day => {
    const info  = forecast[day] || { summary: "good", slots: [] };
    const cond  = info.summary || "good";
    const label = cond === "good" ? "Good" : "Bad";
    const slots = info.slots || [];
    const dayId = `weather-detail-${day}`;

    const slotsHtml = slots.length > 0
      ? slots.map(s => {
          const timeStr = `${String(s.hour).padStart(2, "0")}:00`;
          const tempStr = `${s.temp}°`;
          const icon = condIcon[s.condition] || "☀️";
          return `
            <div class="weather-slot ${s.condition}">
              <span class="slot-time">${timeStr}</span>
              <span class="slot-icon">${icon}</span>
              <span class="slot-temp">${tempStr}</span>
              <span class="slot-desc">${s.description}</span>
            </div>`;
        }).join("")
      : '<div class="weather-slot-empty">No hourly data</div>';

    return `
      <div class="weather-day-block">
        <div class="weather-row weather-row-toggle" onclick="toggleWeatherDetail('${dayId}')">
          <span class="weather-day">${capitalize(day.slice(0, 3))}</span>
          <span class="weather-badge ${cond}">${condIcon[cond]} ${label}</span>
          <span class="weather-chevron" id="chevron-${dayId}">${slots.length > 0 ? "▸" : ""}</span>
        </div>
        <div class="weather-detail" id="${dayId}" style="display:none">
          ${slotsHtml}
        </div>
      </div>`;
  }).join("");
}

function toggleWeatherDetail(id) {
  const el = document.getElementById(id);
  const chevron = document.getElementById("chevron-" + id);
  if (!el) return;
  const visible = el.style.display !== "none";
  el.style.display = visible ? "none" : "flex";
  if (chevron) chevron.textContent = visible ? "▸" : "▾";
}

function updateAltCounter() {
  if (totalScheduleCount === 0) {
    altCounter.textContent = "click to load";
    btnPrev.disabled = true;
    btnNext.disabled = false;  // allow first click to trigger load
    return;
  }
  altCounter.textContent = `${currentScheduleIndex + 1} / ${totalScheduleCount}`;
  btnPrev.disabled = currentScheduleIndex <= 0;
  btnNext.disabled = currentScheduleIndex >= totalScheduleCount - 1;
}

// ===== HELPERS =====

/**
 * Convert day name + HH:MM to ISO datetime string for FullCalendar.
 * Uses the current week's Monday as the base date.
 */
function dayTimeToISO(dayName, time) {
  const days = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"];
  const today = new Date();
  const monday = new Date(today);
  monday.setDate(today.getDate() - ((today.getDay() + 6) % 7));  // get this week's Monday

  const dayOffset = days.indexOf(dayName.toLowerCase());
  const date = new Date(monday);
  date.setDate(monday.getDate() + dayOffset);

  const [h, m] = time.split(":").map(Number);
  date.setHours(h, m, 0, 0);

  return date.toISOString();
}

function formatTime(date) {
  return date.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
}

function formatSubject(subject) {
  return subject.replace(/_/g, " ").replace(/\b\w/g, l => l.toUpperCase());
}

function capitalize(str) {
  return str.charAt(0).toUpperCase() + str.slice(1);
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Pick black or white text based on background luminance.
 */
function contrastColor(hex) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return luminance > 0.55 ? "#1e1e2e" : "#ffffff";
}

function showLoading(msg = "Working...") {
  loadingMsg.textContent = msg;
  loadingOverlay.style.display = "flex";
}

function hideLoading() {
  loadingOverlay.style.display = "none";
}

function showError(msg) {
  renderWarnings([`Error: ${msg}`]);
  document.getElementById("warnings-section").style.display = "flex";
}

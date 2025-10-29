load("encoding/base64.star", "base64")
load("encoding/json.star", "json")
load("http.star", "http")
load("humanize.star", "humanize")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

SERVICE_URL = "http://ics-calendar-tidbyt:8080"
#SERVICE_URL = "http://localhost:8080"

def main(config):
    location = config.str(P_LOCATION)
    location = json.decode(location) if location else {}
    timezone = location.get(
        "timezone",
        config.get("$tz", DEFAULT_TIMEZONE),
    )

    hours_window = int(config.str(P_HOURS_TO_CONSIDER, DEFAULT_HOURS_TO_CONSIDER))

    # Read color settings
    colors = {
        "primary": config.str(P_PRIMARY_COLOR, DEFAULT_PRIMARY_COLOR),
        "frame_bg": config.str(P_FRAME_BG_COLOR, DEFAULT_FRAME_BG_COLOR),
        "soon": config.str(P_SOON_COLOR, DEFAULT_SOON_COLOR),
        "imminent": config.str(P_IMMINENT_COLOR, DEFAULT_IMMINENT_COLOR),
        "event_text": config.str(P_EVENT_TEXT_COLOR, DEFAULT_EVENT_TEXT_COLOR),
    }
    show_full_names = config.bool("show_full_names", DEFAULT_SHOW_FULL_NAMES)
    use_24_hour = config.bool(P_USE_24_HOUR, DEFAULT_USE_24_HOUR)

    ics_url = config.str("ics_url", DEFAULT_ICS_URL)
    show_in_progress = config.bool("show_in_progress", DEFAULT_SHOW_IN_PROGRESS)

    # get all day variable, set default to "showAllDay"
    all_day_behavior = config.get("all_day", "showAllDay")
    if (all_day_behavior == "onlyShowAllDay"):
        only_show_all_day = True
        include_all_day = True
    elif (all_day_behavior == "noShowAllDay"):
        include_all_day = False
        only_show_all_day = False
    else:
        # default behavior is to show all day
        include_all_day = True
        only_show_all_day = False

    if (ics_url == None):
        fail("ICS_URL not set in config")

    now = time.now().in_location(timezone)
    ics = http.post(
        url = SERVICE_URL,
        json_body = {"icsUrl": ics_url, "tz": timezone, "showInProgress": show_in_progress, "includeAllDayEvents": include_all_day, "onlyShowAllDayEvents": only_show_all_day},
    )

    if (ics.status_code != 200):
        print("HTTP request failed with status", ics.status_code)
        return []

    event = ics.json()["data"]

    # No events at all -> skip app
    if not event:
        return []

    # Calculate window inclusion
    is_within_window = event["detail"]["inProgress"] or event["detail"]["minutesUntilStart"] <= hours_window * 60

    # If in progress and not all-day, show the event frame
    if event["detail"]["inProgress"] and not event["detail"]["isAllDay"]:
        return build_event_frame(event, colors, now)

    # If outside the window, skip app
    if not is_within_window:
        return []

    # Otherwise render the calendar frame
    return build_calendar_frame(now, timezone, event, hours_window, show_full_names, use_24_hour, colors)

def get_calendar_text_color(event, colors):
    DEFAULT = colors["primary"]
    if event["detail"]["isAllDay"]:
        return DEFAULT
    elif event["detail"]["minutesUntilStart"] <= 2:
        return colors["imminent"]
    elif event["detail"]["minutesUntilStart"] <= 5:
        return colors["soon"]
    else:
        return DEFAULT

def should_animate_text(event):
    if event["detail"]["isAllDay"]:
        return False
    return event["detail"]["minutesUntilStart"] <= 5

def get_tomorrow_text_copy(eventStart, show_full_names, use_24_hour):
    DEFAULT = eventStart.format("TMRW " + ("15:04" if use_24_hour else "3:04 PM"))
    if show_full_names:
        return eventStart.format("Tomorrow at " + ("15:04" if use_24_hour else "3:04 PM"))
    else:
        return DEFAULT

def get_this_week_text_copy(eventStart, show_full_names, use_24_hour):
    DEFAULT = eventStart.format("Mon at " + ("15:04" if use_24_hour else "3:04 PM"))

    if show_full_names:
        return eventStart.format("Monday at " + ("15:04" if use_24_hour else "3:04 PM"))
    else:
        return DEFAULT

def get_expanded_time_text_copy(event, now, eventStart, eventEnd, show_full_names, use_24_hour):
    DEFAULT = "in %s" % humanize.relative_time(now, eventStart)

    multiday = False

    # check if it's a multi-day event
    if event["detail"]["isAllDay"] and eventStart.day != eventEnd.day:
        multiday = True

    if event["detail"]["isAllDay"]:
        # if it's in progress, show the day it ends
        if event["detail"]["inProgress"] and multiday:
            return eventEnd.format("until Mon")  # + " " + humanize.ordinal(eventEnd.day)
            # if the event is all day and ends today, show nothing

        elif event["detail"]["inProgress"]:
            return eventEnd.format("")
            # if the event is all day but not started, just show the day it starts

        else:
            return eventStart.format("on Mon")
    elif event["detail"]["isTomorrow"]:
        return get_tomorrow_text_copy(eventStart, show_full_names, use_24_hour)

    elif event["detail"]["isThisWeek"]:
        return get_this_week_text_copy(eventStart, show_full_names, use_24_hour)
    else:
        return DEFAULT

def get_calendar_text_copy(event, now, eventStart, eventEnd, hours_window, show_full_names, use_24_hour):
    DEFAULT = eventStart.format("at " + ("15:04" if use_24_hour else "3:04 PM"))

    is_within_window = event["detail"]["inProgress"] or event["detail"]["minutesUntilStart"] <= hours_window * 60

    if event["detail"] and not event["detail"]["isAllDay"] and event["detail"]["minutesUntilStart"] <= 10:
        if event["detail"]["minutesUntilStart"] < 1:
            return "now"
        else:
            return "in %d min" % event["detail"]["minutesUntilStart"]
    if event["detail"] and is_within_window:
        return get_expanded_time_text_copy(event, now, eventStart, eventEnd, show_full_names, use_24_hour)
    else:
        return DEFAULT

def get_calendar_render_data(now, usersTz, event, hours_window, show_full_names, use_24_hour, colors):
    baseObject = {
        "currentMonth": now.format("Jan").upper(),
        "currentDay": humanize.ordinal(now.day),
        "now": now,
    }

    #if there's no event or it is an all day event, build the top part of calendar as usual
    if not event:
        baseObject["hasEvent"] = False
        return baseObject

    is_within_window = event["detail"]["inProgress"] or event["detail"]["minutesUntilStart"] <= hours_window * 60
    shouldRenderSummary = event["detail"]["isToday"] or is_within_window
    if not shouldRenderSummary:
        baseObject["hasEvent"] = False
        return baseObject

    startTime = time.from_timestamp(int(event["start"])).in_location(usersTz)
    endTime = time.from_timestamp(int(event["end"])).in_location(usersTz)
    eventObject = {
        "summary": event["name"],
        "eventStartTimestamp": startTime,
        "copy": get_calendar_text_copy(event, now, startTime, endTime, hours_window, show_full_names, use_24_hour),
        "textColor": get_calendar_text_color(event, colors),
        "shouldAnimateText": should_animate_text(event),
        "hasEvent": True,
        "isToday": event["detail"]["isToday"],
        "isAllDay": event["detail"]["isAllDay"],
    }

    return dict(baseObject.items() + eventObject.items())

def render_calendar_base_object(top, bottom, bg_color):
    return render.Root(
        delay = FRAME_DELAY,
        child = render.Box(
            padding = 2,
            color = bg_color,
            child = render.Column(
                expanded = True,
                children = top + bottom,
            ),
        ),
    )

def get_calendar_top(data, colors):
    return [
        render.Row(
            cross_align = "center",
            expanded = True,
            children = [
                render.Image(src = CALENDAR_ICON, width = 9, height = 11),
                render.Box(width = 2, height = 1),
                render.Text(
                    data["currentMonth"],
                    color = colors["primary"],
                    offset = -1,
                ),
                render.Box(width = 1, height = 1),
                render.Text(
                    data["currentDay"],
                    color = colors["primary"],
                    offset = -1,
                ),
            ],
        ),
        render.Box(height = 2),
    ]

def get_calendar_bottom(data):
    children = []
    if data["hasEvent"]:
        children.append(
            render.Marquee(
                width = 64,
                child = render.Text(
                    data["summary"],
                ),
            ),
        )
        children.append(
            render.Marquee(
                width = 64,
                child = render.Text(
                    data["copy"],
                    color = data["textColor"],
                ),
            ),
        )

    elif data["shouldAnimateText"]:
        children = [
            render.Animation(
                children,
            ),
        ]

    return [
        render.Column(
            expanded = True,
            main_align = "end",
            children = children,
        ),
    ]

def build_calendar_frame(now, usersTz, event, hours_window, show_full_names, use_24_hour, colors):
    data = get_calendar_render_data(now, usersTz, event, hours_window, show_full_names, use_24_hour, colors)

    # top half displays the calendar icon and date
    top = get_calendar_top(data, colors)
    bottom = get_calendar_bottom(data)

    # if it's an all day event, build the calendar up top and drop the name of the event below
    #something goes here

    # bottom half displays the upcoming event, if there is one.
    # otherwise it just shows the time.

    return render_calendar_base_object(
        top = top,
        bottom = bottom,
        bg_color = colors["frame_bg"],
    )

def get_event_frame_copy_config(event):
    minutes_to_start = event["detail"]["minutesUntilStart"]
    minutes_to_end = event["detail"]["minutesUntilEnd"]
    hours_to_end = event["detail"]["hoursToEnd"]

    if minutes_to_start >= 1:
        tagline = "in %d min" % minutes_to_start
    elif hours_to_end >= 99:
        tagline = "now"
    elif minutes_to_end >= 99:
        tagline = "Ends in %dh" % hours_to_end
    elif minutes_to_end > 1:
        tagline = "Ends in %dmin" % minutes_to_end
    else:
        tagline = "almost done"

    return {
        "summary": event["name"],
        "tagline": tagline,
        "bgColor": "#ff78e9",
        "textColor": "#fff500",
    }

def build_event_frame(event, colors, now):
    dataObj = get_event_frame_copy_config(event)

    data = {
        "currentMonth": now.format("Jan").upper(),
        "currentDay": humanize.ordinal(now.day),
        "summary": dataObj["summary"],
        "copy": dataObj["tagline"],
        "textColor": colors["event_text"],
        "shouldAnimateText": False,
        "hasEvent": True,
    }

    top = get_calendar_top(data, colors)
    bottom = get_calendar_bottom(data)

    return render_calendar_base_object(
        top = top,
        bottom = bottom,
        bg_color = colors["frame_bg"],
    )

def get_schema():
    options = [
        schema.Option(
            display = "Show All Day Events",
            value = "showAllDay",
        ),
        schema.Option(
            display = "Only Show All Day Events",
            value = "onlyShowAllDay",
        ),
        schema.Option(
            display = "Don't Show All Day Events",
            value = "noShowAllDay",
        ),
    ]

    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(
                id = P_LOCATION,
                name = "Location",
                desc = "Location for the display of date and time.",
                icon = "locationDot",
            ),
            schema.Text(
                id = P_ICS_URL,
                name = "iCalendar URL",
                desc = "The URL of the iCalendar file.",
                icon = "calendar",
                default = DEFAULT_ICS_URL,
            ),
            schema.Text(
                id = P_HOURS_TO_CONSIDER,
                name = "Hours to Consider",
                desc = "Number of hours ahead to include.",
                default = DEFAULT_HOURS_TO_CONSIDER,
                icon = "clock",
            ),
            schema.Toggle(
                id = P_SHOW_FULL_NAMES,
                name = "Show Full Names",
                desc = "Show the full names of the days of the week.",
                default = DEFAULT_SHOW_FULL_NAMES,
                icon = "calendar",
            ),
            schema.Toggle(
                id = P_SHOW_IN_PROGRESS,
                name = "Show Events In Progress",
                desc = "Show events that are currently happening.",
                default = DEFAULT_SHOW_IN_PROGRESS,
                icon = "calendar",
            ),
            schema.Toggle(
                id = P_USE_24_HOUR,
                name = "Use 24-Hour Time",
                desc = "Format times using 24-hour clock.",
                default = DEFAULT_USE_24_HOUR,
                icon = "clock",
            ),
            schema.Dropdown(
                id = P_ALL_DAY,
                name = "Show All Day Events",
                desc = "Turn on or off display of all day events.",
                default = options[0].value,
                options = options,
                icon = "calendar",
            ),
            # Colors
            schema.Color(
                id = P_PRIMARY_COLOR,
                name = "Primary Color",
                desc = "Primary accent color (e.g., month/day, upcoming text).",
                default = DEFAULT_PRIMARY_COLOR,
                icon = "brush",
            ),
            schema.Color(
                id = P_FRAME_BG_COLOR,
                name = "Frame Background Color",
                desc = "Background color of the calendar frame.",
                default = DEFAULT_FRAME_BG_COLOR,
                icon = "brush",
            ),
            schema.Color(
                id = P_SOON_COLOR,
                name = "Soon Color",
                desc = "Color when event starts within 5 minutes.",
                default = DEFAULT_SOON_COLOR,
                icon = "brush",
            ),
            schema.Color(
                id = P_IMMINENT_COLOR,
                name = "Imminent Color",
                desc = "Color when event starts imminently.",
                default = DEFAULT_IMMINENT_COLOR,
                icon = "brush",
            ),
            schema.Color(
                id = P_EVENT_TEXT_COLOR,
                name = "Event Frame Text Color",
                desc = "Text color for in-progress event frame.",
                default = DEFAULT_EVENT_TEXT_COLOR,
                icon = "brush",
            ),
        ],
    )

P_LOCATION = "location"
P_ICS_URL = "ics_url"
P_HOURS_TO_CONSIDER = "hours_to_consider"
P_SHOW_FULL_NAMES = "show_full_names"
P_SHOW_IN_PROGRESS = "show_in_progress"
P_ALL_DAY = "all_day"
P_USE_24_HOUR = "use_24_hour"

# Color parameter keys
P_PRIMARY_COLOR = "primary_color"
P_FRAME_BG_COLOR = "frame_bg_color"
P_SOON_COLOR = "soon_color"
P_IMMINENT_COLOR = "imminent_color"
P_EVENT_TEXT_COLOR = "event_text_color"

DEFAULT_HOURS_TO_CONSIDER = "24"
DEFAULT_SHOW_FULL_NAMES = False
DEFAULT_SHOW_IN_PROGRESS = True
DEFAULT_TIMEZONE = "America/New_York"
DEFAULT_USE_24_HOUR = False

# Default colors
DEFAULT_PRIMARY_COLOR = "#ff83f3"
DEFAULT_FRAME_BG_COLOR = "#000"
DEFAULT_SOON_COLOR = "#ff5000"
DEFAULT_IMMINENT_COLOR = "#ff5000"
DEFAULT_EVENT_TEXT_COLOR = "#fff500"
FRAME_DELAY = 100

CALENDAR_ICON = base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAkAAAALCAYAAACtWacbAAAAAXNSR0IArs4c6QAAAE9JREFUKFNjZGBgYJgzZ87/lJQURlw0I0xRYEMHw/qGCgZ0GqSZ8a2Myv8aX1eGls27GXDRYEUg0/ABxv///xOn6OjRowzW1tYMuOghaxIAD/ltSOskB+YAAAAASUVORK5CYII=")

#this is a weird calendar but its the only public ics that reliably has events every week
DEFAULT_ICS_URL = "https://calendar.google.com/calendar/ical/ht3jlfaac5lfd6263ulfh4tql8%40group.calendar.google.com/public/basic.ics"

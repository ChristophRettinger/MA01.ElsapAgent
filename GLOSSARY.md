# ELSAP Agent

Scripts that work with ELSAP (the City of Vienna's external time-sheet system, "Externe Leistungserfassung") where a contractor logs working hours against purchase-order items.

## Language

**Time sheet**:
A record in ELSAP for one order item and service in one reporting period, against which hours are logged. German UI term: _Leistungsblatt_.
_Avoid_: Timesheet, work sheet

**Order item**:
One item of a purchase order (order number + item number) under which services are billed.
_Avoid_: Project (the project name is display text only, not a key)

**Service**:
The role or rate tier within an order item, for example "SW-Developer*in" or "Std.Satz < 12/24". German UI term: _Leistung_.
_Avoid_: Role, offering

**Position key**:
The combination of order number, item number and service number that uniquely identifies a time sheet. Project name and role text are descriptive extras.
_Avoid_: Project ID

**Bookable**:
A time sheet is bookable when its order item is neither marked as delivery-complete nor deleted. Only bookable time sheets are tracked. German UI term: _Bebuchbar_.
_Avoid_: Open, active

**Ordered hours**:
The hours ordered for a time sheet. Can change afterwards through obligo splitting._Avoid_: Total hours, budget, plan

**Open hours**:
The part of the ordered hours not yet consumed, i.e. still available for booking. Independent of the reporting period._Avoid_: Remaining budget, available hours

**Obligo splitting**:
A later re-distribution of an order that can change the ordered hours of a time sheet.

**Reporting period**:
The month for which time sheets are displayed and booked in ELSAP. Ordered and open hours do not depend on it.

**Snapshot**:
The ordered and open hours of all bookable time sheets as read in one run.

**Change**:
A difference between two consecutive snapshots: a time sheet appeared, disappeared, or its ordered or open hours differ.

**Known change**:
A manually recorded event, such as a booking by a person, that is expected to cause a change in the hours of a time sheet. Known changes are kept separately from the snapshot history.
_Avoid_: Comment, annotation

**Explained**:
A change is explained when known changes for the same time sheet, dated shortly before the run that detected it, add up to its hours difference. It is partially explained when they add up to less or more, and unexplained when none apply.
_Avoid_: Matched, verified

# iOS alert callbacks retain action strings

Date: 2026-09-09
Status: accepted
Ticket: MOB-53

## Context

The iOS alert and action-sheet NIFs decode each button action into an
`NSString`, then create a `UIAlertAction` whose handler runs later. The old code
stored `[action UTF8String]` in a `const char *` outside the handler and captured
that pointer. Those bytes belong to the string and are not guaranteed to remain
valid until the user selects the action. Short action names often appeared to
work, which made the error easy to miss.

## Decision

Each `UIAlertAction` handler captures its `NSString` action. The handler obtains
the UTF-8 pointer when it runs and passes it directly to
`mob_deliver_alert_action`. That function constructs the Erlang term before it
returns, so the pointer is used only while the captured string is still alive.

Apply the same rule to any delayed Objective-C callback: retain the object whose
value is needed, then obtain temporary C pointers inside the callback that
consumes them.

## Consequences

- Alert and action-sheet callbacks deliver the action value decoded for their
  own button, even after the presenting NIF has returned.
- The native regression test checks both handlers and ignores commented source,
  so restoring the earlier pointer capture fails the suite.
- A future delivery helper that stores the pointer after returning would require
  copying the bytes; the current synchronous helper does not.

# The wall panel: a screen that cannot overflow

Two Android tablets on walls, running a kiosk app that loads the dashboard. One is the main
board, one sits by the door. Fixed screen, landscape, no scrolling, read from one to two
metres away.

## The failure

The first versions clipped text. Not in an obvious way: a card looked fine and was quietly
cutting the bottom line off. The owner's report was blunt, "it's all broken", and he was right.

The instinct is to tune heights until it fits. That fails on the next Tuesday, because the
content is not constant: seven calendar events instead of two, a three-line metro advisory,
one more bill, a longer track title.

## Rule one: constant cardinality

**No region renders a list whose length depends on the data.**

The board shows one upcoming thing. Four status beads. Five rooms. Always exactly that,
whatever the data does. Seven calendar events cannot break the layout because the board
renders one.

This converts height from a function of unpredictable content into a function of type size,
which is a variable under control.

## Rule two: scale, do not hide

An earlier version hid pieces when space ran short, dropping the least important line until
the content fit. It worked, and it was wrong: losing the "next bill" row is exactly what reads
as broken, while losing 8% of type size is invisible.

Each region now shrinks its own type until it fits, down to about a third if it must. Facts
are never removed.

Two things that only appeared once this was running:

- the fitter must only touch the DOM when the region actually changed size or overflows.
  Re-measuring on every tick produced 24 attribute mutations a minute, which is the flicker
  the whole exercise existed to remove.
- anything that rewrites DOM after the fit has to re-fit. The music card was being re-inflated
  by the Spotify poll right after the board had fitted it, so it clipped again on every track
  change.

## The cause no CSS would have fixed

Everything measured clean on a desktop at 1280x800, the tablet's exact resolution, while the
tablet kept clipping.

The Android WebView multiplies every font size by the **system font scale**. A device with
larger text set enlarges the entire layout on top of a design that has no room to give.
Measured by simulating the scale:

| System font scale | Cards clipping |
|---|---|
| 100% | none |
| 115% | 4 |
| 130% | 5 |

Two fixes: the kiosk flavour of the app pins `textZoom = 100`, because a fixed-purpose
appliance should not inherit a phone's accessibility setting; and the board measures the real
rendered scale at runtime and compensates, so it survives even where that pin does not apply.

## The corner that ate taps

The design brief included "I hate that pile of things in the top right corner". Investigating
it turned up something better than a taste argument: the native kiosk app places a 96dp
invisible view in that exact corner to catch the seven-tap exit gesture, and it **consumes
touches**. Every control that had ever lived there was in a dead zone.

The corner is now empty by rule, and the utilities live in a sheet behind a discreet handle
next to the clock.

## Measuring instead of looking

The harness is not clever. Headless Chrome, a script, a number.

**Clipping**, per tile, comparing content height against box height, and the bottom edge of
every child against the bottom of its parent. With the finance values *revealed*, because they
are masked by default and every earlier test had exercised the wrong state:

```
CLIP  kcommute   over=  65  pastBottom= 34  "tap for the full advisory"
CLIP  klab       over=  56  pastBottom= 24  "wall panels · 1/1 online"
CLIP  kfinance   over=  36  pastBottom= 25  "spent today €5.62..."
```

**Flicker**, as DOM mutations over 70 idle seconds. A full repaint every 30 seconds became
1 mutation, which is the clock ticking.

**Behaviour**, not appearance: a test that clicks a light toggle and asserts that the label
and the state change together caught a real bug where the button lit up while still reading
OFF, because the handler only flipped the class.

## Night

The main tablet lives in a bedroom. From the dim hour it fades to black with a faint clock and
nothing else, and any touch brings the full board back for a minute. The first touch only
wakes it, so a hand brushing past in the dark cannot turn on a light.

This was implemented as a layer over any kiosk screen rather than a render mode of the board.
The earlier version redrew the board to enter and leave the mode, which is why the transition
looked broken.

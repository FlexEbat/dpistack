// A newest-wins ticket for screens that load on a timer and on a click.
// Every load takes a ticket; only the holder of the newest one may show its
// answer, its error and schedule the next poll. Without it two loads in
// flight (a click on a range or a filter during a poll, a tab coming back
// into view) answer in any order: the older answer overwrites the newer one,
// and each load schedules a poll of its own, so the screen asks twice as
// often until it is closed.
export function tickets() {
  let n = 0;
  return {
    next: () => ++n,
    current: (t) => t === n,
  };
}

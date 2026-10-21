package export

import (
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/metrics"
)

// In NFQUEUE mode (IPS) Suricata has no kernel drop counter: there is no
// drop ratio, and never a made-up zero.
func TestDropRatioNeedsKernelCounters(t *testing.T) {
	kernel := func(packets, drops uint64) metrics.Stats { return metrics.Stats{Packets: packets, Drops: drops} }
	nfq := func(packets uint64) metrics.Stats { return metrics.Stats{Packets: packets, NoKernel: true} }

	if r, ok := dropRatio(kernel(100, 1), kernel(200, 3)); !ok || r != 0.02 {
		t.Errorf("kernel counters: ratio %v ok=%v, want 0.02", r, ok)
	}
	if _, ok := dropRatio(nfq(100), nfq(200)); ok {
		t.Error("a ratio from NFQUEUE stats, which have no drop counter")
	}
	if _, ok := dropRatio(nfq(100), kernel(200, 0)); ok {
		t.Error("a ratio across a switch from NFQUEUE to af-packet")
	}
}

// MobDemo-Bridging-Header.h — Exposes Mob ObjC types to Swift.
// Passed to swiftc via -import-objc-header.

#import "MobNode.h"

// Called from MobHostingController to signal a back gesture to the BEAM.
// Implemented in mob_nif.m; looks up :mob_screen and sends {:mob, :back}.
void mob_handle_back(void);

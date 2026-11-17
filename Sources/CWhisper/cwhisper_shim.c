// SwiftPM needs at least one source file in a C target. The implementation comes from the
// prebuilt whisper.cpp static libraries in Vendor/whisper/lib (see scripts/bootstrap-whisper.sh).
#include "whisper.h"

const char * cwhisper_shim_version(void) { return whisper_version(); }

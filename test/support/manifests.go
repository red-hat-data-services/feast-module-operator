/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package support

import (
	"os"
	"strings"
	"testing"
)

// OverlayParam reads a key from the given overlay's params.env bundled under
// config/manifests. Use feastoperator.OverlayFor to map a platform type to
// the overlay name.
func OverlayParam(t *testing.T, overlay string, key string) string {
	t.Helper()

	path := MustProjectFile("config", "manifests", "feastoperator", overlay, "params.env")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s params.env: %v", overlay, err)
	}

	for _, line := range strings.Split(string(data), "\n") {
		if k, v, found := strings.Cut(line, "="); found && strings.TrimSpace(k) == key {
			return strings.TrimSpace(v)
		}
	}

	t.Fatalf("key %s not found in %s params.env", key, overlay)
	return ""
}

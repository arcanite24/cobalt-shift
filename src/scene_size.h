#pragma once

namespace cobalt {

// Scene size (#23): call once the image is loaded, before guest code runs.
void ApplySceneSize();

}  // namespace cobalt

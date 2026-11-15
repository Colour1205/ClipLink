/*
 * Copyright 2025 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Copied unchanged from androidx.compose.material:material-icons-extended 1.7.8 - only the
// package moved. See io.uaena.cliplink.ui.icons.Icons for why.
package io.uaena.cliplink.ui.icons.outlined

import io.uaena.cliplink.ui.icons.Icons
import io.uaena.cliplink.ui.icons.materialIcon
import io.uaena.cliplink.ui.icons.materialPath
import androidx.compose.ui.graphics.vector.ImageVector

public val Icons.Outlined.SaveAlt: ImageVector
    get() {
        if (_saveAlt != null) {
            return _saveAlt!!
        }
        _saveAlt = materialIcon(name = "Outlined.SaveAlt") {
            materialPath {
                moveTo(19.0f, 12.0f)
                verticalLineToRelative(7.0f)
                lineTo(5.0f, 19.0f)
                verticalLineToRelative(-7.0f)
                lineTo(3.0f, 12.0f)
                verticalLineToRelative(7.0f)
                curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                horizontalLineToRelative(14.0f)
                curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                verticalLineToRelative(-7.0f)
                horizontalLineToRelative(-2.0f)
                close()
                moveTo(13.0f, 12.67f)
                lineToRelative(2.59f, -2.58f)
                lineTo(17.0f, 11.5f)
                lineToRelative(-5.0f, 5.0f)
                lineToRelative(-5.0f, -5.0f)
                lineToRelative(1.41f, -1.41f)
                lineTo(11.0f, 12.67f)
                lineTo(11.0f, 3.0f)
                horizontalLineToRelative(2.0f)
                verticalLineToRelative(9.67f)
                close()
            }
        }
        return _saveAlt!!
    }

private var _saveAlt: ImageVector? = null

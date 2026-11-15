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

public val Icons.Outlined.DevicesOther: ImageVector
    get() {
        if (_devicesOther != null) {
            return _devicesOther!!
        }
        _devicesOther = materialIcon(name = "Outlined.DevicesOther") {
            materialPath {
                moveTo(3.0f, 6.0f)
                horizontalLineToRelative(18.0f)
                lineTo(21.0f, 4.0f)
                lineTo(3.0f, 4.0f)
                curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                verticalLineToRelative(12.0f)
                curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                horizontalLineToRelative(4.0f)
                verticalLineToRelative(-2.0f)
                lineTo(3.0f, 18.0f)
                lineTo(3.0f, 6.0f)
                close()
                moveTo(13.0f, 12.0f)
                lineTo(9.0f, 12.0f)
                verticalLineToRelative(1.78f)
                curveToRelative(-0.61f, 0.55f, -1.0f, 1.33f, -1.0f, 2.22f)
                curveToRelative(0.0f, 0.89f, 0.39f, 1.67f, 1.0f, 2.22f)
                lineTo(9.0f, 20.0f)
                horizontalLineToRelative(4.0f)
                verticalLineToRelative(-1.78f)
                curveToRelative(0.61f, -0.55f, 1.0f, -1.34f, 1.0f, -2.22f)
                reflectiveCurveToRelative(-0.39f, -1.67f, -1.0f, -2.22f)
                lineTo(13.0f, 12.0f)
                close()
                moveTo(11.0f, 17.5f)
                curveToRelative(-0.83f, 0.0f, -1.5f, -0.67f, -1.5f, -1.5f)
                reflectiveCurveToRelative(0.67f, -1.5f, 1.5f, -1.5f)
                reflectiveCurveToRelative(1.5f, 0.67f, 1.5f, 1.5f)
                reflectiveCurveToRelative(-0.67f, 1.5f, -1.5f, 1.5f)
                close()
                moveTo(22.0f, 8.0f)
                horizontalLineToRelative(-6.0f)
                curveToRelative(-0.5f, 0.0f, -1.0f, 0.5f, -1.0f, 1.0f)
                verticalLineToRelative(10.0f)
                curveToRelative(0.0f, 0.5f, 0.5f, 1.0f, 1.0f, 1.0f)
                horizontalLineToRelative(6.0f)
                curveToRelative(0.5f, 0.0f, 1.0f, -0.5f, 1.0f, -1.0f)
                lineTo(23.0f, 9.0f)
                curveToRelative(0.0f, -0.5f, -0.5f, -1.0f, -1.0f, -1.0f)
                close()
                moveTo(21.0f, 18.0f)
                horizontalLineToRelative(-4.0f)
                verticalLineToRelative(-8.0f)
                horizontalLineToRelative(4.0f)
                verticalLineToRelative(8.0f)
                close()
            }
        }
        return _devicesOther!!
    }

private var _devicesOther: ImageVector? = null

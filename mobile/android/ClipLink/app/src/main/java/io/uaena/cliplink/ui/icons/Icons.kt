/*
 * Copyright 2019 The Android Open Source Project
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

package io.uaena.cliplink.ui.icons

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.DefaultFillType
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * The Material icons the app draws, and only those: each one is a copy of
 * androidx.compose.material:material-icons-core / -extended 1.7.8, the same
 * paths, under the same names, so a screen only imports them from here.
 *
 * The extended library is a 37 MB classes.jar for the 29 icons used: every
 * debug APK carried all of it (72 MB), and every release build fed it to R8.
 * material3 no longer brings material-icons-core along, so the few icons
 * from there are copied too. A new icon: copy its file from those sources
 * the same way, changing only the package.
 */
object Icons {
    object Filled

    object Outlined

    /** The icons that mirror themselves in a right-to-left layout. */
    object AutoMirrored {
        object Filled

        object Outlined
    }
}

/** material-icons-core's builder for one icon: 24 by 24 dp, on a 24 by 24 viewport. */
internal inline fun materialIcon(
    name: String,
    autoMirror: Boolean = false,
    block: ImageVector.Builder.() -> ImageVector.Builder,
): ImageVector = ImageVector.Builder(
    name = name,
    defaultWidth = MATERIAL_ICON_DIMENSION.dp,
    defaultHeight = MATERIAL_ICON_DIMENSION.dp,
    viewportWidth = MATERIAL_ICON_DIMENSION,
    viewportHeight = MATERIAL_ICON_DIMENSION,
    autoMirror = autoMirror,
).block().build()

/** material-icons-core's path with Material defaults - one shape of an icon. */
internal inline fun ImageVector.Builder.materialPath(
    fillAlpha: Float = 1f,
    strokeAlpha: Float = 1f,
    pathFillType: PathFillType = DefaultFillType,
    pathBuilder: PathBuilder.() -> Unit,
) = path(
    fill = SolidColor(Color.Black),
    fillAlpha = fillAlpha,
    stroke = null,
    strokeAlpha = strokeAlpha,
    strokeLineWidth = 1f,
    strokeLineCap = StrokeCap.Butt,
    strokeLineJoin = StrokeJoin.Bevel,
    strokeLineMiter = 1f,
    pathFillType = pathFillType,
    pathBuilder = pathBuilder,
)

/** Every Material icon is 24 by 24. */
internal const val MATERIAL_ICON_DIMENSION = 24f

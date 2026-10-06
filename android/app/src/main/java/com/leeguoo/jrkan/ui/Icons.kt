package com.leeguoo.jrkan.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * Material has no badminton glyph; this is a shuttlecock drawn on the same
 * 24-unit grid as the other tab icons (cork at the bottom, feather skirt).
 */
val ShuttlecockIcon: ImageVector = ImageVector.Builder(
    name = "Shuttlecock", defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f,
).apply {
    path(fill = SolidColor(Color.Black)) {
        // Feather skirt: a trapezoid widening upwards, with notches on top.
        moveTo(6f, 3f)
        lineTo(8f, 4.2f)
        lineTo(10f, 3f)
        lineTo(12f, 4.2f)
        lineTo(14f, 3f)
        lineTo(16f, 4.2f)
        lineTo(18f, 3f)
        lineTo(14.6f, 14f)
        lineTo(9.4f, 14f)
        close()
    }
    path(fill = SolidColor(Color.Black)) {
        // Cork: a half-dome under the skirt.
        moveTo(9f, 15.2f)
        lineTo(15f, 15.2f)
        lineTo(15f, 17f)
        arcTo(3f, 3f, 0f, isMoreThanHalf = false, isPositiveArc = true, x1 = 9f, y1 = 17f)
        close()
    }
}.build()

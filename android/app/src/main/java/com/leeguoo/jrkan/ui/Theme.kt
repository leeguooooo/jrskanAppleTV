package com.leeguoo.jrkan.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * The same palette as the Apple apps (DesignSystem.swift `Palette`): black
 * canvas, iOS dark grouped-cell grey, leeguoo's cobalt accent, coral live.
 */
object Palette {
    val accent = Color(0xFF8094FF)
    val live = Color(0xFFFF5447)
    val background = Color.Black
    /** iOS secondarySystemBackground in dark mode. */
    val cell = Color(0xFF1C1C1E)
    val cellPressed = Color(0xFF2C2C2E)
    val separator = Color(0x5454589E)
    val primaryText = Color.White
    val secondaryText = Color(0x99EBEBF5)
    val tertiaryText = Color(0x4DEBEBF5)
    val fill = Color(0x3D767680)
    val star = Color(0xFFFFD60A)
    val flame = Color(0xFFFF9F0A)
}

private val colors = darkColorScheme(
    primary = Palette.accent,
    onPrimary = Color.Black,
    secondary = Palette.accent,
    background = Palette.background,
    onBackground = Palette.primaryText,
    surface = Palette.background,
    onSurface = Palette.primaryText,
    surfaceVariant = Palette.cell,
    onSurfaceVariant = Palette.secondaryText,
    surfaceContainerLowest = Palette.background,
    surfaceContainerLow = Palette.cell,
    surfaceContainer = Palette.cell,
    surfaceContainerHigh = Palette.cellPressed,
    surfaceContainerHighest = Palette.cellPressed,
    secondaryContainer = Color(0xFF2A2F55),
    onSecondaryContainer = Palette.primaryText,
    outline = Palette.separator,
    outlineVariant = Palette.separator,
    error = Palette.live,
)

@Composable
fun JrkanTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors, content = content)
}

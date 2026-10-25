package com.leeguoo.jrkan.ui

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import com.leeguoo.jrkan.R

/**
 * The scoreboard palette shared with the Apple apps: warm near-black ground,
 * amber for actions and score digits, red only for live, green only for the
 * "auto line is fine" check. Property names are kept from the previous
 * palette so every screen picks the new tokens up.
 */
object Palette {
    /** Amber: primary action buttons and the big score digits. */
    val accent = Color(0xFFFFB000)
    /** Text on an amber button. */
    val onAccent = Color(0xFF100E0C)
    val live = Color(0xFFFF4D2E)
    val ok = Color(0xFF30D158)
    val background = Color(0xFF100E0C)
    val cell = Color(0xFF1A1714)
    val cellPressed = Color(0xFF24201B)
    /** Hairlines and card borders. */
    val separator = Color(0xFF2E2924)
    val primaryText = Color(0xFFF3EBDD)
    val secondaryText = Color(0xFF8C8274)
    val tertiaryText = Color(0xFF5C544A)
    val fill = Color(0x14FFECD2)
    val star = Color(0xFFFFB000)
    val flame = Color(0xFFFF9F0A)
    /** Team comparison bars. */
    val home = Color(0xFF5B8DEF)
    val away = Color(0xFFFFB000)
    /** Translucent control surface over video. */
    val glass = Color(0xBD1A1714)
    val glassBorder = Color(0x29FFECD2)
}

/** 8dp everywhere: cards, buttons, tab bar. No pill capsules. */
val ScoreShape = RoundedCornerShape(8.dp)

object Fonts {
    /** LED digits for big scores. */
    val led = FontFamily(Font(R.font.vt323_regular, FontWeight.Normal))
    /** Numbers and Latin labels. */
    val chakra = FontFamily(
        Font(R.font.chakra_petch_semibold, FontWeight.SemiBold),
        Font(R.font.chakra_petch_bold, FontWeight.Bold),
    )
    /**
     * Noto Serif SC Black, subset to [HEADING_GLYPHS] only. Use it through
     * [headingFamily]; never for dynamic text.
     */
    private val serifHeading = FontFamily(Font(R.font.noto_serif_sc_heading, FontWeight.Black))

    /** Every character in the subset font (mirrors the pyftsubset --text list). */
    const val HEADING_GLYPHS = "今日比赛正在进行稍后开始未开赛已结束其他最近观看全部篮球羽毛球足球热门关注线路数据球员球队分节赛况对比载入"

    /** The serif only when every character is in the subset; system sans otherwise. */
    fun headingFamily(text: String): FontFamily? =
        if (text.isNotEmpty() && text.all { it in HEADING_GLYPHS }) serifHeading else null
}

/** VT323 digits in amber with a soft glow. VT323 has one weight; never ask for bold. */
fun ledStyle(size: TextUnit, color: Color = Palette.accent, glow: Boolean = true) = TextStyle(
    fontFamily = Fonts.led,
    fontWeight = FontWeight.Normal,
    fontSize = size,
    color = color,
    fontFeatureSettings = "tnum",
    shadow = if (glow) Shadow(Palette.accent.copy(alpha = 0.55f), Offset.Zero, blurRadius = 14f) else null,
)

/** Chakra Petch for numbers and Latin labels, tabular figures. */
fun chakraStyle(size: TextUnit, weight: FontWeight = FontWeight.SemiBold, color: Color = Color.Unspecified) = TextStyle(
    fontFamily = Fonts.chakra,
    fontWeight = weight,
    fontSize = size,
    color = color,
    fontFeatureSettings = "tnum",
)

/** The ground: #100E0C with a faint amber dot grid, tiled from one small bitmap. */
@Composable
fun Modifier.scoreboardGround(): Modifier {
    val density = LocalDensity.current
    val brush = remember(density) {
        val step = with(density) { 6.dp.roundToPx() }.coerceAtLeast(4)
        val bitmap = Bitmap.createBitmap(step, step, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Palette.background.toArgb())
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            color = Palette.accent.copy(alpha = 0.07f).compositeOver(Palette.background).toArgb()
        }
        android.graphics.Canvas(bitmap).drawCircle(step / 2f, step / 2f, with(density) { 1.dp.toPx() }, paint)
        ShaderBrush(ImageShader(bitmap.asImageBitmap(), TileMode.Repeated, TileMode.Repeated))
    }
    return this.background(brush)
}

private fun Color.compositeOver(background: Color): Color {
    val a = alpha
    return Color(
        red = red * a + background.red * (1 - a),
        green = green * a + background.green * (1 - a),
        blue = blue * a + background.blue * (1 - a),
        alpha = 1f,
    )
}

private val colors = darkColorScheme(
    primary = Palette.accent,
    onPrimary = Palette.onAccent,
    secondary = Palette.accent,
    onSecondary = Palette.onAccent,
    tertiary = Palette.accent,
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
    secondaryContainer = Color(0xFF3A2E14),
    onSecondaryContainer = Palette.primaryText,
    outline = Palette.separator,
    outlineVariant = Palette.separator,
    error = Palette.live,
)

private val shapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(8.dp),
    large = RoundedCornerShape(8.dp),
    extraLarge = RoundedCornerShape(8.dp),
)

@Composable
fun JrkanTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors, shapes = shapes) {
        // Screens drawn straight on the ground (no Surface/Scaffold) still get light text.
        CompositionLocalProvider(LocalContentColor provides Palette.primaryText, content = content)
    }
}

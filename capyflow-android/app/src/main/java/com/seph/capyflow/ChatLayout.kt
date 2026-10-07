package com.seph.capyflow

import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.HorizontalAlignmentLine
import androidx.compose.ui.layout.layout

/** Propagates the bubble's center through its timestamp/name column to the avatar row. */
val ChatBubbleCenter = HorizontalAlignmentLine { first, second -> minOf(first, second) }

fun Modifier.chatBubbleCenter(): Modifier = layout { measurable, constraints ->
    val bubble = measurable.measure(constraints)
    layout(bubble.width, bubble.height, mapOf(ChatBubbleCenter to bubble.height / 2)) {
        bubble.placeRelative(0, 0)
    }
}

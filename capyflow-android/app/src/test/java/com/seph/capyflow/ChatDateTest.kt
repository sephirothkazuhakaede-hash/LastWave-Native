package com.seph.capyflow
import org.junit.Test
import org.junit.Assert.*
import java.time.*
class ChatDateTest {
    @Test fun calendarDaysCrossMidnightAndYear() {
        val zone=ZoneId.systemDefault()
        val now=LocalDate.of(2026,1,1)
        val today=now.atTime(0,5).atZone(zone).toInstant().toEpochMilli()
        val yesterday=now.minusDays(1).atTime(23,55).atZone(zone).toInstant().toEpochMilli()
        assertEquals("Today",chatDateLabel(today,now))
        assertEquals("Yesterday",chatDateLabel(yesterday,now))
        assertNotEquals(chatDay(today),chatDay(yesterday))
        assertNotEquals("Yesterday",chatDateLabel(now.minusDays(3).atStartOfDay(zone).toInstant().toEpochMilli(),now))
    }
}

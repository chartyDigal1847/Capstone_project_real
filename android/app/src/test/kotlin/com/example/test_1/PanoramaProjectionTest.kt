package com.example.test_1

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PanoramaProjectionTest {
    @Test fun overlappingViewsCoverEveryOneDegreeSphericalSampleIncludingPolesAndSeam() {
        for (latitude in -90..90) for (longitude in -180..179) {
            assertTrue("uncovered lon=$longitude lat=$latitude", PanoramaProjection.isCovered(longitude.toDouble(), latitude.toDouble()))
        }
        assertTrue(PanoramaProjection.isCovered(-180.0, 90.0))
        assertTrue(PanoramaProjection.isCovered(180.0, -90.0))
    }

    @Test fun seamCrossingMaskProducesTwoNonOverlappingImageSpans() {
        assertEquals(listOf(4055 to 4096, 0 to 102), PanoramaProjection.horizontalSegments(.99, .035, 4096))
    }

    @Test fun ordinaryMaskRemainsOneSpan() {
        assertEquals(listOf(1024 to 1229), PanoramaProjection.horizontalSegments(.25, .05, 4096))
    }
}

<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

Schedule::command('localspot:backup')->dailyAt('02:15');
Schedule::command('localspot:expire-location-sessions')->everyFiveMinutes();
Schedule::command('localspot:process-recognition-jobs')->everyMinute();
Schedule::command('localspot:purge-tour-originals')->dailyAt('03:10');

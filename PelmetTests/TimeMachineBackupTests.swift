// TimeMachineBackupTests.swift
// `tmutil status` prints a header line and then an old-style plist whose
// numbers arrive as strings; the Time Machine item reads running, stopping,
// phase and percent out of it.

import Foundation
import Testing
@testable import Pelmet

struct TimeMachineBackupTests {
    @Test func idleStatusParses() {
        let output = """
        Backup session status:
        {
            ClientID = "com.apple.backupd";
            Percent = "-1";
            Running = 0;
        }
        """
        let status = TimeMachineBackup.parseStatus(output)
        #expect(status?.running == false)
        #expect(status?.percent == nil)
        #expect(status?.stopping == false)
        #expect(status?.phase == nil)
    }

    @Test func runningStatusCarriesPhaseAndPercent() {
        let output = """
        Backup session status:
        {
            BackupPhase = Copying;
            ClientID = "com.apple.backupd";
            DateOfStateChange = "2026-09-16 12:32:20 +0000";
            DestinationID = "D8D25560-B008-4957-A73E-1E8AB84924C5";
            Percent = "0.4237";
            Running = 1;
            Stopping = 0;
        }
        """
        let status = TimeMachineBackup.parseStatus(output)
        #expect(status?.running == true)
        #expect(status?.phase == "Copying")
        #expect(status?.percent.map { abs($0 - 0.4237) < 0.0001 } == true)
        #expect(status?.stopping == false)
    }

    @Test func preparingHasNoPercentAndStoppingReads() {
        let output = """
        Backup session status:
        {
            BackupPhase = FindingBackupVol;
            Percent = "-1";
            Running = 1;
            Stopping = 1;
        }
        """
        let status = TimeMachineBackup.parseStatus(output)
        #expect(status?.running == true)
        #expect(status?.percent == nil)
        #expect(status?.stopping == true)
    }

    @Test func garbageIsNil() {
        #expect(TimeMachineBackup.parseStatus(nil) == nil)
        #expect(TimeMachineBackup.parseStatus("tmutil: not permitted") == nil)
    }
}

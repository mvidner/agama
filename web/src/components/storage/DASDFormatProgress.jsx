/*
 * Copyright (c) [2023] SUSE LLC
 *
 * All Rights Reserved.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of version 2 of the GNU General Public License as published
 * by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, contact SUSE LLC.
 *
 * To contact SUSE LLC about this file by physical or electronic mail, you may
 * find current contact information at www.suse.com.
 */

import React, { useEffect, useState } from "react";
import { Progress, Skeleton } from '@patternfly/react-core';
import { If, Popup } from "~/components/core";
import { useInstallerClient } from "~/context/installer";

export default function DASDFormatProgress({ job, devices, isOpen = true }) {
  const { storage: client } = useInstallerClient();
  const [progress, setProgress] = useState(undefined);

  useEffect(() => {
    client.dasd.onFormatProgress(job.path, p => setProgress(p));
  }, [client.dasd, job.path]);

  const ProgressContent = ({ progress }) => {
    return (
      <div className="stack dasd-format-progress">
        { Object.entries(progress).map(([path, [total, step, done]]) => {
          const device = devices.find(d => d.id === path.split("/").slice(-1)[0]);

          return (
            <Progress
              key={path}
              size="sm"
              max={total}
              value={step}
              title={`${device.channelId} - ${device.name}`}
              measureLocation="none"
              variant={done ? "success" : undefined}
            />
          );
        })}
      </div>
    );
  };

  const WaitingProgress = () => (
    <div className="stack">
      <div>Waiting for progress report</div>
      <Skeleton height="10px" />
      <Skeleton height="10px" />
    </div>
  );

  return (
    <Popup
      title="Formatting DASD devices"
      isOpen={isOpen}
      disableFocusTrap
    >

      <If
        condition={progress}
        then={<ProgressContent progress={progress} />}
        else={<WaitingProgress />}
      />
    </Popup>
  );
}

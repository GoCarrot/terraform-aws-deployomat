# frozen_string_literal: true

# Copyright 2026 Teak.io, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and

require 'aws-sdk-ec2'

# Finds the git commit an AMI was built from, for the notification. The image builds tag
# every AMI `BuildCommit` (CIRCLE_SHA1; `in-dev` for a build outside CI).
#
# This only ever adds detail to a notification, so it never raises: any problem is a line on
# stderr (which also lands in the log group) and no commit. Those lines tell apart the
# causes that look the same in the notification:
#   * the AMI has no tag (a build that didn't set it),
#   * this account is not the AMI's owner (EC2 doesn't show tags to an account an AMI is only
#     shared with, so every lookup would come back untagged),
#   * EC2 has no such AMI for this account (gone, or not shared with it),
#   * the call itself failed (no ec2:DescribeImages on the Lambda role, say).
module AmiCommit
  TAG = 'BuildCommit'

  # The tag's value, or nil. A deploy's AmiId can also be a command ($name-prefix:...,
  # $launchtemplate:...) that the deploy resolves later; those have no AMI to look at.
  def self.lookup(ami, region:, account:)
    return nil unless ami.to_s.start_with?('ami-')

    client = Aws::EC2::Client.new(region: region, retry_limit: 1, http_open_timeout: 2, http_read_timeout: 5)
    image = client.describe_images(image_ids: [ami]).images.first
    return warn_nil("#{ami} not found, or not shared with this account") if image.nil?

    value = image.tags&.find { |t| t.key == TAG }&.value
    return value unless value.nil? || value.empty?

    if account && image.owner_id != account
      warn_nil("this account is not the owner of #{ami} (owner #{image.owner_id}, this account #{account}); " \
               'tags are not visible to it')
    else
      warn_nil("#{ami} has no #{TAG} tag")
    end
  rescue Aws::EC2::Errors::InvalidAMIIDNotFound
    warn_nil("#{ami} not found, or not shared with this account")
  rescue StandardError => e
    warn_nil("could not describe #{ami}: #{e.class}: #{e.message}")
  end

  def self.warn_nil(message)
    $stderr.puts("ami commit: #{message}")
    nil
  end
end

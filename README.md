[![Gem Version](https://badge.fury.io/rb/harvest-reaper.svg)](https://badge.fury.io/rb/harvest-reaper)

# Reaper

`Reaper` is a smart Harvest filling helepr. 

Usually you only need three steps:

1. Login to `Harvest` and authorize `Reaper`.
2. Set the configuration to let reaper know all your tasks and the workload in a week.
3. Run `reaper submit current` once each week to submit your time entries. Reaper will generate a random set for you based on your configuration. Unless your login access token is expired or your tasks are changed, step 3 is the only action you have to perform in the coming weeks.

# Installation

```shell
gem install harvest-reaper
```

After reaper is successfully installed, you can type `reaper` in the terminal to see all the available commands.

# Login

```shell
reaper login
```

The `Harvest` login page will open in your browser and then ask you to grant the permission to `Reaper` (The authorization page may directly show if you already signed in). After clicking `Authorize App` button, `Reaper` will get the Harvest access token and request your account info. After this process the login action is successful.

Your Harvest access token will be expired after around two weeks. You only need to run login command once before its expiry date.

# Configuration

## Overview

You must set the configuration before submitting time entries. There are two kinds of settings in the configuration.

### Global Settings

Currently there are two properties: `Daily working hours negative offset` and `Daily working hours positive offset`. They are used to make your daily working hours more random. By default Reaper assumes the daily working hours are 8. After setting the offset, when calculating the time entries, your working hours each day will be a random number between `8 - negative offset` to `8 + positive offset`. E.g., say you set negative offset to 1 and positive offset to 2, your working hours will vary each day between 7 - 10.

### Projects/Tasks Settings

These settings could have multiple entries. Each entry represents a task and the workload in a week, which contains three parameters: a project, a task belongs to the project, and a percentage number (0 - 100). The sum of all the percentage numbers must be 100.

## Update configuration

Run the following command to set or update your configuration:

```shell
reaper config update
```

Reaper will try to fetch your project list first, and then launch a local webpage to help you to update the configuration conveniently.

## Show configuration

```shell
reaper config show
```

## Delete configuration

```shell
reaper config delete
```

# Time Entries Management

## Overview

A `time entry` is the minimum unit of a Harvest record. You can create time entries with two types: via **duration ** or via **start and end time**. Reaper only supports creating time entries via duration.

![image](https://user-images.githubusercontent.com/669206/62857084-43c7ff00-bd29-11e9-8463-304a1050521e.png)

Reaper manages time entries per week (weekdays only), and always treats Monday as the first day. 

To avoid the data conflict, Reaper will check your time entries in the specified week first before submitting. If existing time entries are found, Reaper will stop and ask you to manually delete them first (See `Advanced` section for exceptions).

To submit or delete time entries of a week, Reaper actually has to send a series of requests for each time entry one by one. So if there's any error occured during the requests, your Harvest records may be in an incorrect intermidiate state. You need to take care of such situations:

- If it's failed to delete time entries, run delete command again.
- If it's failed to submit time entries, run delete command first to make sure the specified week is in a clean state, then run submit command again.

## Commands

There are three commands related to time entries:

- **Show time entries of a given week**: 

  ```shell
  reaper show {DATE/WEEK-ALIAS}
  ```

- **Submit time entries for a given week, based on the configuration**:

  ```shell
  reaper submit {DATE/WEEK-ALIAS}
  ```

- **Delete time entries in a given week**:

  ```shell
  reaper delete {Date/WEEK-ALIAS}
  ```

The argument accepts four strings/string formats to convert to a week range (from Monday to Friday):

1. `yyyymmdd` or `mmdd`: Reaper will calculate a week range which includes the given date. If `mmdd` is provided, Reaper will assume it represents a date in the current year.
2. `current`: Reaper will calculate a week range based on *current week*.
3. `last`: Reaper will calculate a week range based on *last week*.

## Examples

- View time entries in the current week:

  ```shell
  reaper show current
  ```

- Submit time entries for the last week:

- ```shell
  reaper submit last
  ```

- Delete time entries in the week of 8 Aug, 2019:

- ```shell
  reaper delete 20190808
  ```

  

# Advanced

## Prefilled Holidays by Admin

Sometimes the admin will submit the 8-hours time entries for you when there are public holidays. Reaper is smart enough to detect such cases. It will ask you if you want to exclude the holidays and only submit the time entries for the rest of the days.

## Submit Time Entries with Manually Excluded Days

Command `submit` accepts an argument `—excluded`. You could type a command like this:

```shell
reaper submit 0812 --excluded mon,wed
```

Reaper will exclude Monday and Wedesday, but only calculate and submit the time entries for the rest of 3 days.

The valid options for `—excluded` are `mon, tue, wed, thu, fri`. You could provide 1 - 4 weekdays. If multiple weekdays are provided, separate them by commas.

# Milktea Time

If you find Reaper saves your time a lot, please consider running `reaper donate` and buy me a milktea. ❤️

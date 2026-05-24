defmodule CodexPoolerWeb.Admin.JobsPresentation.State do
  @moduledoc false

  @default_job_state_presentation %{
    icon: "hero-question-mark-circle",
    icon_class: "mx-auto size-5 text-base-content/60",
    badge_class: "border-base-300 bg-base-200 text-base-content/70",
    label: nil
  }

  @job_state_presentations %{
    "completed" => %{
      icon: "hero-check-circle",
      icon_class: "mx-auto size-5 text-success",
      badge_class: "border-success/40 bg-success/10 text-success",
      label: nil
    },
    "discarded" => %{
      icon: "hero-x-circle",
      icon_class: "mx-auto size-5 text-error",
      badge_class: "border-error/40 bg-error/10 text-error",
      label: nil
    },
    "cancelled" => %{
      icon: "hero-no-symbol",
      icon_class: "mx-auto size-5 text-warning",
      badge_class: "border-warning/40 bg-warning/10 text-warning",
      label: nil
    },
    "executing" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      badge_class: "border-info/40 bg-info/10 text-info",
      label: nil
    },
    "retryable" => %{
      icon: "hero-exclamation-triangle",
      icon_class: "mx-auto size-5 text-warning",
      badge_class: "border-warning/40 bg-warning/10 text-warning",
      label: nil
    },
    "available" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      badge_class: "border-info/40 bg-info/10 text-info",
      label: nil
    },
    "scheduled" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      badge_class: "border-info/40 bg-info/10 text-info",
      label: nil
    },
    "awaiting_first_run" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      badge_class: "border-info/40 bg-info/10 text-info",
      label: "Awaiting first run"
    },
    "idle" => %{
      icon: "hero-minus-circle",
      icon_class: "mx-auto size-5 text-base-content/40",
      badge_class: "border-base-300 bg-base-200 text-base-content/70",
      label: "No observed run"
    }
  }

  @spec icon(String.t() | nil) :: String.t()
  def icon(state), do: presentation(state).icon

  @spec icon_class(String.t() | nil) :: String.t()
  def icon_class(state), do: presentation(state).icon_class

  @spec badge_class(String.t() | nil) :: String.t()
  def badge_class(state), do: presentation(state).badge_class

  @spec label(String.t() | nil) :: String.t()
  def label(nil), do: "Unknown"

  def label(state) do
    case presentation(state).label do
      nil -> state |> to_string() |> String.replace("_", " ") |> String.capitalize()
      label -> label
    end
  end

  defp presentation(state),
    do: Map.get(@job_state_presentations, state, @default_job_state_presentation)
end

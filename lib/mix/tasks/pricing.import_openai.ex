defmodule Mix.Tasks.Pricing.ImportOpenai do
  use Mix.Task

  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.OpenAIPricingImporter

  @default_path "priv/pricing/openai/pricing.json"

  @shortdoc "Import OpenAI pricing snapshots from JSON"

  @moduledoc """
  Imports OpenAI pricing snapshots into the database.

  Uses #{@default_path} by default.

  ## Usage

      mix pricing.import_openai
      mix pricing.import_openai --path PATH
      mix pricing.import_openai -p PATH
      mix pricing.import_openai PATH
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    path = parse_path(args)

    path
    |> import_path()
    |> print_or_raise(path)
  end

  defp parse_path(args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args, strict: [path: :string], aliases: [p: :path])

    Keyword.get(opts, :path) || List.first(rest) || @default_path
  end

  defp import_path(@default_path), do: Catalog.import_openai_pricing_from_priv()
  defp import_path(path), do: OpenAIPricingImporter.import_file(path)

  defp print_or_raise({:ok, result}, _path) do
    Mix.shell().info(
      "imported=#{result.inserted} skipped=#{result.skipped} total=#{result.total} " <>
        "source=#{result.source} price_version=#{result.price_version}"
    )
  end

  defp print_or_raise({:error, %{code: code, message: message}}, path) do
    Mix.raise("pricing import failed for #{path}: [#{code}] #{message}")
  end
end

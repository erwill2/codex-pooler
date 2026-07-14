defmodule CodexPooler.Gateway.Runtime.ModelUnavailable do
  @moduledoc false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext

  @compact_endpoint "/backend-api/codex/responses/compact"
  @invalid_request_error "invalid_request_error"
  @model_not_found "model_not_found"

  @spec http_error?(non_neg_integer(), binary(), SelectedCandidateContext.t()) :: boolean()
  def http_error?(status, body, %SelectedCandidateContext{} = context)
      when is_integer(status) and is_binary(body) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
         error when is_map(error) <- error_payload(decoded) do
      explicit_model_not_found?(error) or
        (status == 404 and ambiguous_model_error?(error) and catalog_provenance?(context))
    else
      _invalid_or_unrelated -> false
    end
  end

  def http_error?(_status, _body, _context), do: false

  @spec failure_signature?(map()) :: boolean()
  def failure_signature?(failure) when is_map(failure) do
    explicit_model_not_found?(failure) or ambiguous_model_error?(failure)
  end

  def failure_signature?(_failure), do: false

  @spec failure?(map(), SelectedCandidateContext.t()) :: boolean()
  def failure?(failure, %SelectedCandidateContext{} = context) when is_map(failure) do
    explicit_model_not_found?(failure) or
      (ambiguous_model_error?(failure) and catalog_provenance?(context))
  end

  def failure?(_failure, _context), do: false

  @spec retryable_failure?(map(), SelectedCandidateContext.t()) :: boolean()
  def retryable_failure?(failure, %SelectedCandidateContext{} = context) do
    failure?(failure, context) and failover_allowed?(context)
  end

  def retryable_failure?(_failure, _context), do: false

  @spec failover_allowed?(SelectedCandidateContext.t()) :: boolean()
  def failover_allowed?(
        %SelectedCandidateContext{
          allow_retry?: true,
          endpoint: endpoint
        } = context
      ) do
    endpoint != @compact_endpoint and not hard_pinned?(context)
  end

  def failover_allowed?(%SelectedCandidateContext{}), do: false

  defp explicit_model_not_found?(error) do
    codes = primary_error_codes(error)

    @model_not_found in codes or
      (codes == [] and @model_not_found in type_codes(error))
  end

  defp ambiguous_model_error?(error) do
    codes = primary_error_codes(error)

    invalid_request_error? =
      @invalid_request_error in codes or
        (codes == [] and @invalid_request_error in type_codes(error))

    invalid_request_error? and error_param(error) == "model"
  end

  defp primary_error_codes(error) do
    [map_value(error, :code), map_value(error, :upstream_code)]
    |> Enum.flat_map(&nested_codes/1)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp type_codes(error) do
    error
    |> map_value(:type)
    |> nested_codes()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp nested_codes(value) when is_binary(value), do: [value]

  defp nested_codes(value) when is_map(value) do
    [map_value(value, :code), map_value(value, :type)]
    |> Enum.filter(&is_binary/1)
  end

  defp nested_codes(_value), do: []

  defp error_param(error) do
    map_value(error, :upstream_error_param) || map_value(error, :param)
  end

  defp error_payload(decoded) do
    case map_value(decoded, :error) do
      error when is_map(error) -> error
      _missing -> nested_error_payload(decoded)
    end
  end

  defp nested_error_payload(decoded) do
    get_in(decoded, ["response", "error"]) ||
      get_in(decoded, ["response", "status_details", "error"]) ||
      get_in(decoded, ["status_details", "error"])
  end

  defp catalog_provenance?(%SelectedCandidateContext{
         assignment: %{id: assignment_id},
         model: %Model{} = model
       })
       when is_binary(assignment_id) do
    case get_in(model.metadata || %{}, ["source_assignment_ids"]) do
      assignment_ids when is_list(assignment_ids) -> assignment_id in assignment_ids
      _missing -> false
    end
  end

  defp catalog_provenance?(%SelectedCandidateContext{}), do: false

  defp hard_pinned?(%SelectedCandidateContext{
         request_options: %RequestOptions{} = request_options,
         model: %Model{} = model
       }) do
    not is_nil(SessionContinuity.hard_pin_metadata(request_options, model))
  end

  defp hard_pinned?(%SelectedCandidateContext{}), do: false

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end

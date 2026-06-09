defmodule XamalProxy.Certificate.PEM do
  @moduledoc """
  Extracts certificate metadata from PEM using Erlang/OTP `:public_key`.
  """

  require Record

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @type metadata :: %{
          optional(:expires_at) => DateTime.t(),
          optional(:serial_number) => integer()
        }

  @spec metadata(binary()) :: {:ok, metadata()} | {:error, term()}
  def metadata(pem) when is_binary(pem) do
    with {:ok, certificate} <- first_certificate(pem),
         {:ok, expires_at} <- certificate_expires_at(certificate) do
      {:ok,
       %{
         expires_at: expires_at,
         serial_number: serial_number(certificate)
       }}
    end
  end

  @spec expires_at(binary()) :: {:ok, DateTime.t()} | {:error, term()}
  def expires_at(pem) when is_binary(pem) do
    with {:ok, metadata} <- metadata(pem) do
      Map.fetch(metadata, :expires_at)
    end
  end

  defp first_certificate(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.find(&match?({:Certificate, _der, _params}, &1))
    |> case do
      nil ->
        {:error, :missing_certificate_pem}

      {:Certificate, der, _params} ->
        {:ok, :public_key.pkix_decode_cert(der, :otp)}
    end
  rescue
    ArgumentError -> {:error, :invalid_certificate_pem}
  end

  defp certificate_expires_at(certificate) do
    certificate
    |> certificate(:tbsCertificate)
    |> tbs_certificate(:validity)
    |> validity(:notAfter)
    |> parse_asn1_time()
  end

  defp serial_number(certificate) do
    certificate
    |> certificate(:tbsCertificate)
    |> tbs_certificate(:serialNumber)
  end

  defp parse_asn1_time({:utcTime, value}) do
    value
    |> to_string()
    |> parse_utc_time()
  end

  defp parse_asn1_time({:generalTime, value}) do
    value
    |> to_string()
    |> parse_general_time()
  end

  defp parse_asn1_time(other), do: {:error, {:unsupported_asn1_time, other}}

  defp parse_utc_time(<<year::binary-size(2), rest::binary>>) do
    with {year, ""} <- Integer.parse(year),
         {:ok, datetime} <- parse_time(century_year(year), rest) do
      {:ok, datetime}
    else
      _error -> {:error, :invalid_utc_time}
    end
  end

  defp parse_utc_time(_value), do: {:error, :invalid_utc_time}

  defp parse_general_time(<<year::binary-size(4), rest::binary>>) do
    with {year, ""} <- Integer.parse(year),
         {:ok, datetime} <- parse_time(year, rest) do
      {:ok, datetime}
    else
      _error -> {:error, :invalid_general_time}
    end
  end

  defp parse_general_time(_value), do: {:error, :invalid_general_time}

  defp parse_time(
         year,
         <<month::binary-size(2), day::binary-size(2), hour::binary-size(2),
           minute::binary-size(2), second::binary-size(2), "Z">>
       ) do
    with {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _error -> {:error, :invalid_asn1_time}
    end
  end

  defp parse_time(_year, _rest), do: {:error, :invalid_asn1_time}

  defp century_year(year) when year >= 50, do: 1900 + year
  defp century_year(year), do: 2000 + year
end

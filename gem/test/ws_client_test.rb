# frozen_string_literal: true

require "test_helper"

class WsClientTest < Minitest::Test
  def test_encode_text_frame_small_payload
    payload = "hello"
    frame = TestQueueTeleport::WsClient.encode_text_frame(payload)

    # First byte: FIN (0x80) | text opcode (0x01) = 0x81
    assert_equal 0x81, frame.getbyte(0)

    # Second byte: MASK (0x80) | length (5) = 0x85
    assert_equal 0x80 | payload.bytesize, frame.getbyte(1)

    # Total: 2 header + 4 mask + 5 payload = 11
    assert_equal 11, frame.bytesize
  end

  def test_encode_text_frame_medium_payload
    payload = "x" * 200
    frame = TestQueueTeleport::WsClient.encode_text_frame(payload)

    # First byte: FIN | text
    assert_equal 0x81, frame.getbyte(0)

    # Second byte: MASK | 126 (extended length marker)
    assert_equal 0x80 | 126, frame.getbyte(1)

    # Bytes 2-3: 16-bit big-endian length
    extended_len = frame.byteslice(2, 2).unpack1("n")
    assert_equal 200, extended_len

    # Total: 2 header + 2 extended length + 4 mask + 200 payload = 208
    assert_equal 208, frame.bytesize
  end

  def test_decode_text_frame
    payload = "hello world"
    # Build an unmasked server text frame
    frame = [0x81, payload.bytesize].pack("CC") + payload.b

    type, decoded = TestQueueTeleport::WsClient.decode_frame(frame)

    assert_equal :text, type
    assert_equal payload, decoded
  end

  def test_decode_close_frame
    # Close frame: FIN | opcode 0x8, length 0
    frame = [0x88, 0x00].pack("CC")

    type, _payload = TestQueueTeleport::WsClient.decode_frame(frame)

    assert_equal :close, type
  end

  def test_round_trip_encode_decode
    original = "round trip test payload"
    frame = TestQueueTeleport::WsClient.encode_text_frame(original)

    # Manually unmask: clear the mask bit and apply mask to payload
    bytes = frame.dup.force_encoding(Encoding::BINARY)

    # Clear MASK bit in second byte
    raw_len = bytes.getbyte(1) & 0x7F
    bytes.setbyte(1, raw_len)

    if raw_len < 126
      mask_offset = 2
    elsif raw_len == 126
      mask_offset = 4
    end

    mask_key = bytes.byteslice(mask_offset, 4)
    payload_offset = mask_offset + 4
    payload_bytes = bytes.byteslice(payload_offset, bytes.bytesize - payload_offset)

    unmasked = payload_bytes.bytes.each_with_index.map { |b, i|
      b ^ mask_key.getbyte(i % 4)
    }.pack("C*")

    # Now rebuild frame without mask
    unmasked_frame = bytes.byteslice(0, mask_offset) + unmasked

    type, decoded = TestQueueTeleport::WsClient.decode_frame(unmasked_frame)

    assert_equal :text, type
    assert_equal original, decoded
  end
end

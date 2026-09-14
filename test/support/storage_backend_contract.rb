# Behaviour every storage backend must show, run against each backend's own
# test class. Including classes define +backend+, returning an instance that
# is safe to write to.
module StorageBackendContract
  ALL_BYTES = (0..255).map(&:chr).join.b.freeze
  LARGE_SAMPLE = Random.new(2024).bytes(300_000).freeze

  def test_name_identifies_the_backend
    assert_match(/\A[a-z0-9_]+\z/, backend.name)
  end

  def test_round_trips_every_byte_value
    key = Storage::Backend.generate_key
    backend.write(key, ALL_BYTES)

    data = backend.read(key)
    assert_equal Encoding::BINARY, data.encoding
    assert_equal ALL_BYTES, data
  end

  def test_round_trips_a_large_object
    key = Storage::Backend.generate_key
    backend.write(key, LARGE_SAMPLE)

    assert_equal LARGE_SAMPLE, backend.read(key)
  end

  def test_round_trips_an_empty_object
    key = Storage::Backend.generate_key
    backend.write(key, "".b)

    assert_equal "", backend.read(key)
  end

  def test_keeps_objects_apart_by_key
    first, second = Storage::Backend.generate_key, Storage::Backend.generate_key
    backend.write(first, "first".b)
    backend.write(second, "second".b)

    assert_equal "first", backend.read(first)
    assert_equal "second", backend.read(second)
  end

  def test_read_of_an_unknown_key_raises_not_found
    error = assert_raises(Storage::NotFound) { backend.read(Storage::Backend.generate_key) }
    assert_kind_of Storage::Error, error
  end

  def test_delete_removes_the_object
    key = Storage::Backend.generate_key
    backend.write(key, "gone soon".b)

    backend.delete(key)

    assert_raises(Storage::NotFound) { backend.read(key) }
  end

  def test_delete_of_an_unknown_key_is_silent
    assert_nothing_raised { backend.delete(Storage::Backend.generate_key) }
  end
end

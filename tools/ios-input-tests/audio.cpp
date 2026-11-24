#include "AZAudioBuffer.h"
#include <cassert>
#include <vector>
int main() {
    AZAudioBuffer buffer;
    int16_t out[8] = {};
    assert(buffer.Pull(out, 4) == 0);
    const int16_t first[] = {1, -1, 2, -2, 3, -3};
    buffer.Push(first, 3);
    assert(buffer.Pull(out, 4) == 3);
    for (int i = 0; i < 6; ++i) assert(out[i] == first[i]);
    assert(out[6] == 0 && out[7] == 0);
    std::vector<int16_t> big((AZAudioBuffer::Capacity + 1) * 2);
    for (size_t i = 0; i < big.size(); ++i) big[i] = static_cast<int16_t>(i);
    buffer.Push(big.data(), AZAudioBuffer::Capacity + 1);
    assert(buffer.Pull(out, 4) == 4);
    for (int i = 0; i < 8; ++i) assert(out[i] == big[i + 2]);
    buffer.Clear();
    assert(buffer.Pull(out, 4) == 0);
    buffer.Push(big.data(), AZAudioBuffer::Capacity);
    buffer.Push(first, 3);
    assert(buffer.Pull(out, 4) == 4);
    assert(out[0] == big[6]);
    buffer.Clear();
    buffer.Push(first, 2);
    assert(buffer.PullBuffered(out, 4, 3) == 0);
    buffer.Push(first + 4, 1);
    assert(buffer.PullBuffered(out, 4, 3) == 3);
    assert(out[0] == 1 && out[4] == 3 && out[6] == 0);
    assert(buffer.PullBuffered(out, 4, 3) == 0);
}

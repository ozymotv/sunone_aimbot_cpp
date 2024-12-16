#include "preprocess.h"
#include "cuda_utils.h"
#include "device_launch_parameters.h"

struct AffineMatrix
{
    float value[6];
};

__global__ void warpaffine_kernel(
    const uint8_t* src,
    int src_line_size,
    int src_width,
    int src_height,
    int num_channels,
    float* dst,
    int dst_width,
    int dst_height,
    uint8_t const_value_st,
    AffineMatrix d2s,
    int edge
) {
    int position = blockDim.x * blockIdx.x + threadIdx.x;
    if (position >= edge) return;

    float m_x1 = d2s.value[0];
    float m_y1 = d2s.value[1];
    float m_z1 = d2s.value[2];
    float m_x2 = d2s.value[3];
    float m_y2 = d2s.value[4];
    float m_z2 = d2s.value[5];

    int dx = position % dst_width;
    int dy = position / dst_width;

    float src_x = m_x1 * dx + m_y1 * dy + m_z1 + 0.5f;
    float src_y = m_x2 * dx + m_y2 * dy + m_z2 + 0.5f;

    float c0, c1, c2;

    if (src_x <= -1 || src_x >= src_width || src_y <= -1 || src_y >= src_height)
    {
        c0 = const_value_st;
        c1 = const_value_st;
        c2 = const_value_st;
    }
    else
    {
        int y_low = floorf(src_y);
        int x_low = floorf(src_x);
        int y_high = y_low + 1;
        int x_high = x_low + 1;

        const uint8_t const_value[] = { const_value_st, const_value_st, const_value_st };

        float ly = src_y - y_low;
        float lx = src_x - x_low;
        float hy = 1 - ly;
        float hx = 1 - lx;

        float w1 = hy * hx;
        float w2 = hy * lx;
        float w3 = ly * hx;
        float w4 = ly * lx;

        const uint8_t* v1 = const_value;
        const uint8_t* v2 = const_value;
        const uint8_t* v3 = const_value;
        const uint8_t* v4 = const_value;

        if (y_low >= 0)
        {
            if (x_low >= 0)
            {
                v1 = src + y_low * src_line_size + x_low * num_channels;
            }
            if (x_high < src_width)
            {
                v2 = src + y_low * src_line_size + x_high * num_channels;
            }
        }
        if (y_high < src_height)
        {
            if (x_low >= 0)
            {
                v3 = src + y_high * src_line_size + x_low * num_channels;
            }
            if (x_high < src_width) {
                v4 = src + y_high * src_line_size + x_high * num_channels;
            }
        }

        if (num_channels >= 3)
        {
            c0 = w1 * v1[0] + w2 * v2[0] + w3 * v3[0] + w4 * v4[0];
            c1 = w1 * v1[1] + w2 * v2[1] + w3 * v3[1] + w4 * v4[1];
            c2 = w1 * v1[2] + w2 * v2[2] + w3 * v3[2] + w4 * v4[2];
        }
        else
        {
            c0 = const_value_st;
            c1 = const_value_st;
            c2 = const_value_st;
        }

        c0 = w1 * v1[0] + w2 * v2[0] + w3 * v3[0] + w4 * v4[0];
        c1 = w1 * v1[1] + w2 * v2[1] + w3 * v3[1] + w4 * v4[1];
        c2 = w1 * v1[2] + w2 * v2[2] + w3 * v3[2] + w4 * v4[2];
    }

    float t = c2;
    c2 = c0;
    c0 = t;

    c0 = c0 / 255.0f;
    c1 = c1 / 255.0f;
    c2 = c2 / 255.0f;

    int area = dst_width * dst_height;
    float* pdst_c0 = dst + dy * dst_width + dx;
    float* pdst_c1 = pdst_c0 + area;
    float* pdst_c2 = pdst_c1 + area;

    *pdst_c0 = c0;
    *pdst_c1 = c1;
    *pdst_c2 = c2;
}

void cuda_preprocess(
    const uint8_t* src,
    int src_width,
    int src_height,
    float* dst,
    int dst_width,
    int dst_height,
    int num_channels,
    cudaStream_t stream)
{
    AffineMatrix s2d, d2s;

    float scale = std::min(
        dst_height / (float)src_height,
        dst_width / (float)src_width
    );

    s2d.value[0] = scale;
    s2d.value[1] = 0;
    s2d.value[2] = -scale * src_width * 0.5f + dst_width * 0.5f;
    s2d.value[3] = 0;
    s2d.value[4] = scale;
    s2d.value[5] = -scale * src_height * 0.5f + dst_height * 0.5f;

    cv::Mat m2x3_s2d(2, 3, CV_32F, s2d.value);
    cv::Mat m2x3_d2s(2, 3, CV_32F, d2s.value);

    cv::invertAffineTransform(m2x3_s2d, m2x3_d2s);

    memcpy(d2s.value, m2x3_d2s.ptr<float>(0), sizeof(d2s.value));

    int jobs = dst_height * dst_width;

    int threads = 256;

    int blocks = (jobs + threads - 1) / threads;

    warpaffine_kernel << <blocks, threads, 0, stream >> > (
        src,
        src_width * num_channels,
        src_width,
        src_height,
        num_channels,
        dst,
        dst_width,
        dst_height,
        128,
        d2s,
        jobs
        );

    CUDA_CHECK(cudaGetLastError());
}
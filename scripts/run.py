import os

wv = "~hzx/data/wiki-vote.g"
mc = "~hzx/data/mico.g"
pt = "~hzx/data/patents.g"
lj = "~hzx/data/livejournal.g"
ok = "~hzx/data/orkut.g"

p1 = "0111010011100011100001100"
p2 = "011011101110110101011000110000101000"
p3 = "011111101000110111101010101101101010"
p4 = "011110101101110000110000100001010010"
p5 = "0111111101111111011101110100111100011100001100000"
p6 = "0111111101111111011001110100111100011000001100000"

if __name__ == '__main__':
    graphs = {'wv': wv, 'pt': pt, 'mc': mc, 'lj': lj, 'ok': ok}
    # graphs = {'wv': wv, 'pt': pt, 'mc': mc}
    # graphs = {'wv': wv, 'pt': pt}
    # graphs = {'mc': mc}
    patterns = [p1, p2, p3, p4, p5, p6]

    from math import sqrt

    for i, p in enumerate(patterns):
        for g_name, g_file in graphs.items():
            log_file1 = 'logs-2/%s-p%d-gpu.txt' % (g_name, i + 1)
            log_file2 = 'logs-2/%s-p%d-cpu.txt' % (g_name, i + 1)

            print('\n>>> Graph: %s Pattern: p%d\n' % (g_name, i + 1))
            os.system('bin/gpu_graph %s %s | tee %s' % (g_file, p, log_file1))
            os.system('bin/baseline_test %s %d %s | tee %s' % (g_file, int(sqrt(len(p))), p, log_file2))
            print('\n<<< Graph: %s Pattern: p%d\n' % (g_name, i + 1))
    
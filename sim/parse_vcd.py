from vcdvcd import VCDVCD

vcd = VCDVCD('sim/tb_tcc_top.vcd')

try:
    tlast = vcd['tb_tcc_top.uut.m_axis_tlast']
    print("m_axis_tlast edges:")
    for tv in tlast.tv:
        print(tv)
except Exception as e:
    print(e)

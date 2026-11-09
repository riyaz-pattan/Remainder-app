import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class CustomIntervalPicker extends StatefulWidget {
  final int initialMinutes;
  const CustomIntervalPicker({super.key, required this.initialMinutes});

  @override
  State<CustomIntervalPicker> createState() => _CustomIntervalPickerState();
}

class _CustomIntervalPickerState extends State<CustomIntervalPicker> {
  late bool _isHours;
  late int _selectedValue;

  @override
  void initState() {
    super.initState();
    if (widget.initialMinutes >= 60 && widget.initialMinutes % 60 == 0) {
      _isHours = true;
      _selectedValue = widget.initialMinutes ~/ 60;
    } else {
      _isHours = false;
      _selectedValue = widget.initialMinutes;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 300,
      color: Colors.white,
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const Text(
                'Custom Interval',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              TextButton(
                onPressed: () {
                  final minutes = _isHours
                      ? _selectedValue * 60
                      : _selectedValue;
                  Navigator.pop(context, minutes);
                },
                child: const Text('Done'),
              ),
            ],
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: CupertinoPicker(
                    scrollController: FixedExtentScrollController(
                      initialItem: _selectedValue - 1,
                    ),
                    itemExtent: 40,
                    onSelectedItemChanged: (index) {
                      setState(() {
                        _selectedValue = index + 1;
                      });
                    },
                    children: List.generate(
                      _isHours ? 12 : 60,
                      (index) => Center(
                        child: Text(
                          '${index + 1}',
                          style: const TextStyle(color: Colors.black),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: CupertinoPicker(
                    scrollController: FixedExtentScrollController(
                      initialItem: _isHours ? 1 : 0,
                    ),
                    itemExtent: 40,
                    onSelectedItemChanged: (index) {
                      setState(() {
                        final wasHours = _isHours;
                        _isHours = index == 1;
                        if (wasHours != _isHours) {
                          // Adjust selected value bounds
                          if (_isHours && _selectedValue > 12) {
                            _selectedValue = 12;
                          }
                        }
                      });
                    },
                    children: const [
                      Center(
                        child: Text(
                          'Minutes',
                          style: TextStyle(color: Colors.black),
                        ),
                      ),
                      Center(
                        child: Text(
                          'Hours',
                          style: TextStyle(color: Colors.black),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
